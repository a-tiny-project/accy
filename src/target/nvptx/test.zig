const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const gpu_abi = @import("gpu_abi");
const accy = @import("../../root.zig");
const pretty = @import("pretty");
const kernel = accy.kernel;
const Allocator = std.mem.Allocator;
const emitPtx = choir.backends.gpu.nvptx.ptx.emitPtx;

const scalar_kernel_name = "accy_cuda_scalar_words";
const scalar_output_count = 8;

fn scalarParameterGraph(allocator: std.mem.Allocator) !kernel.Graph {
    const params = [_]kernel.Param{
        kernel.buffer(.u64, scalar_output_count),
        kernel.scalar(.i64),
        kernel.scalar(.u32),
        kernel.scalar(.u64),
        kernel.scalar(.i32),
    };
    var builder = try kernel.Builder.init(
        allocator,
        kernel.Builder.Limits.testing,
        scalar_kernel_name,
        &params,
    );
    errdefer builder.deinit();
    try builder.bind(try builder.axis("i", 1), .thread_x);
    const signed = builder.argument(1);
    const unsigned = builder.argument(3);
    const bits = try builder.bitcast(signed, .u64);
    const narrow_signed = try builder.cast(builder.argument(4), .i64);
    const signed_sum = try builder.add(signed, narrow_signed);
    const signed_less = try builder.compare(.lt, signed, try builder.bitcast(unsigned, .i64));
    const unsigned_less = try builder.compare(.lt, unsigned, bits);
    const one = try builder.constantInt(.u64, 1);
    const zero = try builder.constantInt(.u64, 0);
    const values = [_]kernel.Value{
        bits,
        unsigned,
        try builder.mul(bits, unsigned),
        try builder.bitcast(signed_sum, .u64),
        try builder.select(signed_less, one, zero),
        try builder.select(unsigned_less, one, zero),
        try builder.cast(builder.argument(2), .u64),
        try builder.bitcast(narrow_signed, .u64),
    };
    const base = try builder.globalId(.x);
    for (values, 0..) |value, offset| {
        const index = try builder.add(base, try builder.constantIndex(@intCast(offset)));
        try builder.store(value, builder.argument(0), index);
    }
    try builder.return_();
    return builder.finish();
}

test "CUDA 64-bit scalar parameters compile from a sealed source graph" {
    var graph = try scalarParameterGraph(std.testing.allocator);
    defer graph.deinit();
    const before = try graph.bodyFingerprint(std.testing.allocator);
    try std.testing.expect(graph.kernelModule().getContext().isFrozen());
    const payload = (try accy.target.compileKernelForArtifactFormat(
        std.testing.allocator,
        .cuda_ptx,
        scalar_kernel_name,
        graph.kernelModule(),
        .{},
    )).payload;
    const text = payload.text;
    defer std.testing.allocator.free(@constCast(text));
    try std.testing.expectEqual(before, try graph.bodyFingerprint(std.testing.allocator));
    try std.testing.expect(std.mem.indexOf(u8, text, ".param .u64 param1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".param .u32 param2,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".param .u64 param3,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "setp.lt.s64") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "setp.lt.u64") != null);
}

const ScalarArguments = struct {
    signed: i64,
    narrow_unsigned: u32,
    unsigned: u64,
    narrow_signed: i32,

    fn launch(self: ScalarArguments) [4]gpu_abi.ScalarArgument {
        return .{
            .{ .i64 = self.signed },   .{ .u32 = self.narrow_unsigned },
            .{ .u64 = self.unsigned }, .{ .i32 = self.narrow_signed },
        };
    }

    fn reference(self: ScalarArguments) [scalar_output_count]u64 {
        const bits: u64 = @bitCast(self.signed);
        const product: u128 = @as(u128, bits) * self.unsigned;
        const sum: i128 = @as(i128, self.signed) + self.narrow_signed;
        return .{
            bits,
            self.unsigned,
            @truncate(product),
            @truncate(@as(u128, @bitCast(sum))),
            @intFromBool(self.signed < @as(i64, @bitCast(self.unsigned))),
            @intFromBool(self.unsigned < bits),
            self.narrow_unsigned,
            @bitCast(@as(i64, self.narrow_signed)),
        };
    }
};

test "CUDA 64-bit scalar parameters preserve every bit on the device" {
    var state = try cudaDevice();
    defer state.deinit();
    const handle = state.handle();
    var graph = try scalarParameterGraph(std.testing.allocator);
    defer graph.deinit();
    var artifact = try kernel.createKernelArtifact(std.testing.allocator, handle, &graph, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "accy/cuda/scalar-parameters",
    });
    defer artifact.deinit();
    try std.testing.expectEqual(@as(u32, 5), artifact.argument_count);
    try std.testing.expectEqual(@as(u32, 4), artifact.scalar_argument_count);
    const loaded = try handle.loadArtifact(&artifact);
    defer handle.destroyObject(loaded.id);
    const output = try handle.allocateBuffer(.{
        .byte_size = scalar_output_count * @sizeOf(u64),
        .alignment = 256,
        .dtype = .u64,
        .element_count = scalar_output_count,
    });
    defer handle.destroyObject(output.id);
    const words = [_]u64{
        0,                     1,                     0xffff_ffff,           0x1_0000_0000,
        0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0xffff_ffff_ffff_ffff,
    };
    const narrow_words = [_]u32{ 0, 1, 0xffff_ffff, 0x8000_0000, 0x7fff_ffff, 0x1234_5678 };
    for (words, 0..) |signed, i| {
        for (words, 0..) |unsigned, j| {
            const args = ScalarArguments{
                .signed = @bitCast(signed),
                .unsigned = unsigned,
                .narrow_unsigned = narrow_words[(i + j) % narrow_words.len],
                .narrow_signed = @bitCast(narrow_words[(i + j + 1) % narrow_words.len]),
            };
            try checkScalarLaunch(handle, &artifact, loaded, output, args);
        }
    }
}

fn cudaDevice() !gpu.cuda.State {
    if (!@import("builtin").link_libc) try accy.validation.gating.skipIfBuildFlagDisabled(.cuda);
    if (!gpu.cuda.platformSupported()) {
        return accy.validation.gating.skip(.cuda, .unsupported_platform);
    }
    return gpu.cuda.State.initDevice(std.testing.allocator, 0) catch |err| {
        if (@import("builtin").link_libc or err != error.RuntimeUnavailable) return err;
        return accy.validation.gating.skip(.cuda, .cuda_runtime_unavailable);
    };
}

fn narrowGraph(allocator: std.mem.Allocator) !kernel.Graph {
    var builder = try kernel.Builder.init(
        allocator,
        kernel.Builder.Limits.testing,
        "accy_cuda_narrow",
        &.{ kernel.buffer(.u64, 4), kernel.scalar(.u64) },
    );
    errdefer builder.deinit();
    try builder.bind(try builder.axis("i", 1), .thread_x);
    const kinds = [_]gpu_abi.DType{ .u8, .i8, .u16, .i16 };
    for (kinds, 0..) |kind, index| {
        const input = try builder.cast(builder.argument(1), kind);
        const sum = try builder.add(input, try builder.constantInt(kind, 1));
        const wide = try builder.cast(sum, .i64);
        const bits = try builder.bitcast(wide, .u64);
        try builder.store(bits, builder.argument(0), try builder.constantIndex(@intCast(index)));
    }
    try builder.return_();
    return builder.finish();
}

test "CUDA narrow arithmetic wraps and sign extends before widening" {
    var state = try cudaDevice();
    defer state.deinit();
    const handle = state.handle();
    var graph = try narrowGraph(std.testing.allocator);
    defer graph.deinit();
    var artifact = try kernel.createKernelArtifact(std.testing.allocator, handle, &graph, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "accy/cuda/narrow",
    });
    defer artifact.deinit();
    const loaded = try handle.loadArtifact(&artifact);
    defer handle.destroyObject(loaded.id);
    const output = try handle.allocateBuffer(.{
        .byte_size = 32,
        .alignment = 256,
        .dtype = .u64,
        .element_count = 4,
    });
    defer handle.destroyObject(output.id);
    const words = [_]u64{
        0, 126, 127, 128, 254, 255, 256, 32767, 32768, 65535, 65536, 0xffff_ffff_ffff_ffff,
    };
    for (words) |word| {
        try handle.launch(.{
            .artifact = &artifact,
            .loaded_artifact = loaded,
            .buffers = &.{.{
                .handle = output,
                .access = .read_write,
                .ownership = output.ownership,
                .byte_size = output.byte_size,
            }},
            .scalar_arguments = &.{.{ .u64 = word }},
            .geometry = .{ .grid = .{ 1, 1, 1 }, .threadgroup = .{ 1, 1, 1 } },
        });
        try handle.synchronize(.{ .scope = .device });
        var observed: [4]u64 = undefined;
        try handle.readBuffer(.{ .handle = output, .bytes = std.mem.asBytes(&observed) });
        const byte: i64 = @intCast((@as(u128, word) + 1) % 256);
        const half: i64 = @intCast((@as(u128, word) + 1) % 65536);
        const expected = [_]u64{
            @intCast(byte),
            @bitCast(if (byte < 128) byte else byte - 256),
            @intCast(half),
            @bitCast(if (half < 32768) half else half - 65536),
        };
        if (!std.mem.eql(u64, &expected, &observed)) {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var report = try pretty.diagnostic.Report.init(
                arena.allocator(),
                "CUDA narrow mismatch",
            );
            defer report.deinit();
            try report.field("input", "{x}", .{word});
            try report.field("expected", "{any}", .{expected});
            try report.field("observed", "{any}", .{observed});
            pretty.diagnostic.writeStderr(&report, .{ .width = 100 });
            return error.NarrowMismatch;
        }
    }
}

fn checkScalarLaunch(
    handle: gpu.BackendHandle,
    artifact: *const gpu.KernelArtifact,
    loaded: gpu.LoadedArtifact,
    output: gpu.BufferHandle,
    args: ScalarArguments,
) !void {
    std.debug.assert(output.byte_size == scalar_output_count * @sizeOf(u64));
    std.debug.assert(artifact.format == .cuda_ptx);
    const scalar_args = args.launch();
    const binding = gpu.BufferBinding{
        .handle = output,
        .access = .read_write,
        .ownership = output.ownership,
        .byte_size = output.byte_size,
    };
    var observed: [scalar_output_count]u64 = @splat(0xa5a5_a5a5_a5a5_a5a5);
    try handle.writeBuffer(.{ .handle = output, .bytes = std.mem.sliceAsBytes(&observed) });
    try handle.launch(.{
        .artifact = artifact,
        .loaded_artifact = loaded,
        .buffers = &.{binding},
        .scalar_arguments = &scalar_args,
        .geometry = .{ .grid = .{ 1, 1, 1 }, .threadgroup = .{ 1, 1, 1 } },
    });
    try handle.synchronize(.{ .scope = .device });
    try handle.readBuffer(.{ .handle = output, .bytes = std.mem.sliceAsBytes(&observed) });
    const expected = args.reference();
    if (!std.mem.eql(u64, &expected, &observed)) {
        try reportScalarMismatch(artifact, args, expected, observed);
        return error.ScalarParameterMismatch;
    }
}

fn reportScalarMismatch(
    artifact: *const gpu.KernelArtifact,
    args: ScalarArguments,
    expected: [scalar_output_count]u64,
    observed: [scalar_output_count]u64,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var report = try pretty.diagnostic.Report.init(
        arena.allocator(),
        "CUDA scalar parameter mismatch",
    );
    defer report.deinit();
    try report.field("backend", "CUDA device 0", .{});
    try report.field("kernel", "{s}", .{scalar_kernel_name});
    try report.field("artifact", "{x}", .{std.hash.Wyhash.hash(0, artifact.payload.text)});
    try report.field("arguments", "{any}", .{args});
    try report.field("expected", "{any}", .{expected});
    try report.field("observed", "{any}", .{observed});
    pretty.diagnostic.writeStderr(&report, .{ .width = 100 });
}

const loop_kernel_name = "accy_cuda_integer_loop";
const loop_output_count = 4;
const loop_first: u64 = 0x1234_5678_9abc_def0;
const loop_second: u64 = 0x6edc_ba98_7654_3210;

const Counter = enum {
    i32,
    index,
    u32,
    i64,
    u64,

    fn parameter(self: Counter) kernel.Param {
        return switch (self) {
            .i32 => kernel.scalar(.i32),
            .index, .u32 => kernel.scalar(.u32),
            .i64 => kernel.scalar(.i64),
            .u64 => kernel.scalar(.u64),
        };
    }

    fn argument(self: Counter, value: i128) gpu_abi.ScalarArgument {
        return switch (self) {
            .i32 => .{ .i32 = @intCast(value) },
            .index, .u32 => .{ .u32 = @intCast(value) },
            .i64 => .{ .i64 = @intCast(value) },
            .u64 => .{ .u64 = @intCast(value) },
        };
    }

    fn starts(self: Counter) []const i128 {
        return switch (self) {
            .i32 => &.{ -1, std.math.minInt(i32), -8, -4, 0, 1, std.math.maxInt(i32) - 16 },
            .index, .u32 => &.{ 0, 1, 0x7fff_fffc, 0x8000_0000, std.math.maxInt(u32) - 16 },
            .i64 => &.{
                -1,          std.math.minInt(i64), -8,                        -4, 0, 1,
                0xffff_fffc, 0x1_0000_0000,        std.math.maxInt(i64) - 16,
            },
            .u64 => &.{
                0,
                1,
                0xffff_fffc,
                0x1_0000_0000,
                0x7fff_ffff_ffff_fffc,
                0x8000_0000_0000_0000,
                std.math.maxInt(u64) - 16,
            },
        };
    }
};

const LoopCase = struct {
    counter: Counter,
    lower: i128,
    upper: i128,
    step: u8,

    fn arguments(self: LoopCase) [3]gpu_abi.ScalarArgument {
        std.debug.assert(self.step > 0);
        return .{
            self.counter.argument(self.lower), self.counter.argument(self.upper),
            self.counter.argument(self.step),
        };
    }

    fn reference(self: LoopCase) [loop_output_count]u64 {
        std.debug.assert(self.step > 0);
        const distance: i128 = @max(0, self.upper - self.lower);
        const count: i128 = @divTrunc(distance + self.step - 1, self.step);
        std.debug.assert(count <= 5);
        const triangle: i128 = @divTrunc(count * (count - 1), 2);
        const sum: i128 = 3 * count * self.lower + 3 * self.step * triangle + 3 * count;
        return .{
            @truncate(@as(u128, @bitCast(sum))),
            if (@mod(count, 2) == 0) loop_first else loop_second,
            if (@mod(count, 2) == 0) loop_second else loop_first,
            @intCast(count),
        };
    }
};

fn loopGraph(allocator: std.mem.Allocator, counter: Counter) !kernel.Graph {
    const parameter = counter.parameter();
    var builder = try kernel.Builder.init(
        allocator,
        kernel.Builder.Limits.testing,
        loop_kernel_name,
        &.{ kernel.buffer(.u64, loop_output_count), parameter, parameter, parameter },
    );
    errdefer builder.deinit();
    try builder.bind(try builder.axis("i", 1), .thread_x);
    var bounds: [3]kernel.Value = undefined;
    for (&bounds, 0..) |*bound, index| {
        const argument = builder.argument(index + 1);
        bound.* = if (counter == .index) try builder.castIndex(argument) else argument;
    }
    const zero = try builder.constantInt(.u64, 0);
    const first = try builder.constantInt(.u64, @bitCast(loop_first));
    const second = try builder.constantInt(.u64, @bitCast(loop_second));
    const word = zero.valueType();
    var scope = try builder.forScope(
        bounds[0],
        bounds[1],
        bounds[2],
        &.{ zero, first, second, zero },
        &.{ word, word, word, word },
    );
    errdefer scope.abort();
    const nested = try nestedLoopValue(&builder, scope.inductionVar());
    const sum = try builder.add(scope.iterArg(0).?, nested);
    const count = try builder.add(scope.iterArg(3).?, try builder.constantInt(.u64, 1));
    try scope.leave(&.{ sum, scope.iterArg(2).?, scope.iterArg(1).?, count });
    for (0..loop_output_count) |index| {
        try builder.store(
            scope.result(index).?,
            builder.argument(0),
            try builder.constantIndex(@intCast(index)),
        );
    }
    try builder.return_();
    return builder.finish();
}

fn nestedLoopValue(builder: *kernel.Builder, outer: kernel.Value) !kernel.Value {
    const value = try builder.cast(outer, .u64);
    const zero = try builder.constantInt(.u64, 0);
    var scope = try builder.forScope(
        try builder.constantIndex(0),
        try builder.constantIndex(3),
        try builder.constantIndex(1),
        &.{zero},
        &.{zero.valueType()},
    );
    errdefer scope.abort();
    const inner = try builder.cast(scope.inductionVar(), .u64);
    const sum = try builder.add(try builder.add(scope.iterArg(0).?, value), inner);
    try scope.leave(&.{sum});
    return scope.result(0).?;
}

test "CUDA structured loops preserve source graphs and counter widths" {
    for (std.enums.values(Counter)) |counter| {
        var graph = try loopGraph(std.testing.allocator, counter);
        defer graph.deinit();
        const before = try graph.bodyFingerprint(std.testing.allocator);
        try std.testing.expect(graph.kernelModule().getContext().isFrozen());
        const payload = (try accy.target.compileKernelForArtifactFormat(
            std.testing.allocator,
            .cuda_ptx,
            loop_kernel_name,
            graph.kernelModule(),
            .{},
        )).payload;
        defer std.testing.allocator.free(@constCast(payload.text));
        try std.testing.expectEqual(before, try graph.bodyFingerprint(std.testing.allocator));
        const comparison = switch (counter) {
            .i32 => "setp.ge.s32",
            .index, .u32 => "setp.ge.u32",
            .i64 => "setp.ge.s64",
            .u64 => "setp.ge.u64",
        };
        try std.testing.expect(std.mem.indexOf(u8, payload.text, comparison) != null);
    }
}

test "CUDA structured loops match independent sums and simultaneous swaps on the device" {
    var state = try cudaDevice();
    defer state.deinit();
    const handle = state.handle();
    for (std.enums.values(Counter)) |counter| try qualifyLoops(handle, counter);
}

fn qualifyLoops(handle: gpu.BackendHandle, counter: Counter) !void {
    var graph = try loopGraph(std.testing.allocator, counter);
    defer graph.deinit();
    var artifact = try kernel.createKernelArtifact(std.testing.allocator, handle, &graph, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "accy/cuda/integer-loops",
    });
    defer artifact.deinit();
    try std.testing.expectEqual(@as(u32, 4), artifact.argument_count);
    try std.testing.expectEqual(@as(u32, 3), artifact.scalar_argument_count);
    const loaded = try handle.loadArtifact(&artifact);
    defer handle.destroyObject(loaded.id);
    const output = try handle.allocateBuffer(.{
        .byte_size = loop_output_count * @sizeOf(u64),
        .alignment = 256,
        .dtype = .u64,
        .element_count = loop_output_count,
    });
    defer handle.destroyObject(output.id);
    for (counter.starts()) |start| {
        for (0..5) |trips| {
            for (1..4) |step| {
                try checkLoopLaunch(handle, &artifact, loaded, output, .{
                    .counter = counter,
                    .lower = start,
                    .upper = start + @as(i128, trips * step - (trips % 2) * (step - 1)),
                    .step = @intCast(step),
                });
            }
        }
    }
    try checkLoopLaunch(handle, &artifact, loaded, output, .{
        .counter = counter,
        .lower = 3,
        .upper = 0,
        .step = 1,
    });
}

fn checkLoopLaunch(
    handle: gpu.BackendHandle,
    artifact: *const gpu.KernelArtifact,
    loaded: gpu.LoadedArtifact,
    output: gpu.BufferHandle,
    case: LoopCase,
) !void {
    std.debug.assert(output.byte_size == loop_output_count * @sizeOf(u64));
    std.debug.assert(artifact.format == .cuda_ptx);
    const arguments = case.arguments();
    const binding = gpu.BufferBinding{
        .handle = output,
        .access = .read_write,
        .ownership = output.ownership,
        .byte_size = output.byte_size,
    };
    var observed: [loop_output_count]u64 = @splat(0xa5a5_a5a5_a5a5_a5a5);
    try handle.writeBuffer(.{ .handle = output, .bytes = std.mem.sliceAsBytes(&observed) });
    try handle.launch(.{
        .artifact = artifact,
        .loaded_artifact = loaded,
        .buffers = &.{binding},
        .scalar_arguments = &arguments,
        .geometry = .{ .grid = .{ 1, 1, 1 }, .threadgroup = .{ 1, 1, 1 } },
    });
    try handle.synchronize(.{ .scope = .device });
    try handle.readBuffer(.{ .handle = output, .bytes = std.mem.sliceAsBytes(&observed) });
    const expected = case.reference();
    if (!std.mem.eql(u64, &expected, &observed)) {
        try reportLoopMismatch(artifact, case, expected, observed);
        return error.IntegerLoopMismatch;
    }
}

fn reportLoopMismatch(
    artifact: *const gpu.KernelArtifact,
    case: LoopCase,
    expected: [loop_output_count]u64,
    observed: [loop_output_count]u64,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var report = try pretty.diagnostic.Report.init(arena.allocator(), "CUDA integer loop mismatch");
    defer report.deinit();
    try report.field("backend", "CUDA device 0", .{});
    try report.field("kernel", "{s}", .{loop_kernel_name});
    try report.field("artifact", "{x}", .{std.hash.Wyhash.hash(0, artifact.payload.text)});
    try report.field("case", "{any}", .{case});
    try report.field("expected", "{any}", .{expected});
    try report.field("observed", "{any}", .{observed});
    pretty.diagnostic.writeStderr(&report, .{ .width = 100 });
}

fn emitLoweredPtx(
    allocator: Allocator,
    entry_name: []const u8,
    program: *accy.kernel.Graph,
) gpu.BackendError![]u8 {
    const ctx = program.kernelModule().getContext();
    const handler = ctx.registerDiagnosticHandler(.{ .handle = reportTestDiagnostic }) catch
        return error.OutOfMemory;
    defer ctx.eraseDiagnosticHandler(handler);
    const payload = (try accy.target.compileKernelForArtifactFormat(
        allocator,
        .cuda_ptx,
        entry_name,
        program.kernelModule(),
        .{},
    )).payload;
    return switch (payload) {
        .text => |text| @constCast(text),
        else => error.InvalidArtifact,
    };
}

fn reportTestDiagnostic(
    _: ?*anyopaque,
    diagnostic: *const choir.diagnostics.Diagnostic,
) !choir.diagnostics.HandlerResult {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var report = try pretty.diagnostic.Report.init(arena.allocator(), diagnostic.message);
    defer report.deinit();
    if (diagnostic.error_name) |name| try report.field("error", "{s}", .{name});
    for (diagnostic.metadata) |entry| try report.field(entry.name, "{s}", .{entry.value});
    pretty.diagnostic.writeStderr(&report, .{ .width = 100 });
    return .consumed;
}

test "cuda choir ptx emitter requires nvptx-lowered gpu ops" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_raw_gpu",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);
    const value = try builder.load(input, index);
    try builder.store(value, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    try testing.expectError(
        error.UnsupportedOperation,
        emitPtx(testing.allocator, "accy_choir_test_raw_gpu", program.kernelModule()),
    );
}

test "cuda choir ptx emitter lowers simple elementwise kernel" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_add",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const lhs = builder.argument(1);
    const rhs = builder.argument(2);
    const count_buffer = builder.argument(3);
    const index = try builder.globalId(.x);
    const zero = try builder.constantIndex(0);
    const count = try builder.load(count_buffer, zero);
    const index_i32 = try builder.cast(index, .i32);
    const in_bounds = try builder.compare(.lt, index_i32, count);
    var if_op = try builder.if_(in_bounds, &.{});
    const previous = builder.insertionBlock();
    builder.setInsertionBlock(if_op.thenBlock());
    const left = try builder.load(lhs, index);
    const right = try builder.load(rhs, index);
    const sum = try builder.add(left, right);
    try builder.store(sum, out, index);
    try builder.yield_(&.{});
    builder.setInsertionBlock(if_op.elseBlock().?);
    try builder.yield_(&.{});
    builder.setInsertionBlock(previous);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_add", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, ".visible .entry accy_choir_test_add") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ld.global.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.global.f32") != null);
    try testing.expect(std.mem.endsWith(u8, text, "}\n"));
    try testing.expectEqual(std.mem.count(u8, text, "{"), std.mem.count(u8, text, "}"));
}

test "cuda choir ptx emitter lowers while loops with carried exits" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_while",
        &params,
    );
    errdefer builder.deinit();
    const src = builder.argument(0);
    const dst = builder.argument(1);
    const index = try builder.globalId(.x);
    const start = try builder.load(src, index);
    const zero = try builder.constantInt(.i32, 0);
    const one = try builder.constantInt(.i32, 1);

    var scope = try builder.whileScope(
        &.{ start, zero },
        &.{ start.valueType(), zero.valueType() },
    );
    errdefer scope.abort();
    const remaining = scope.beforeArg(0).?;
    const total = scope.beforeArg(1).?;
    const proceed = try builder.compare(.gt, remaining, zero);
    try scope.condition(proceed, &.{ remaining, total });
    const after_remaining = scope.afterArg(0).?;
    const after_total = scope.afterArg(1).?;
    const next_total = try builder.add(after_total, after_remaining);
    const next_remaining = try builder.sub(after_remaining, one);
    try scope.leave(&.{ next_remaining, next_total });

    try builder.store(scope.result(1).?, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_while", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "LWHILE_HEAD_") != null);
    try testing.expect(std.mem.indexOf(u8, text, "LWHILE_DONE_") != null);
    try testing.expect(std.mem.indexOf(u8, text, "bra        LWHILE_DONE_") != null);
    try testing.expect(std.mem.indexOf(u8, text, "bra                LWHILE_HEAD_") != null);
    try testing.expect(std.mem.indexOf(u8, text, "setp.gt.s32") != null);
    try testing.expectEqual(std.mem.count(u8, text, "{"), std.mem.count(u8, text, "}"));
}

test "cuda choir ptx emitter lowers value producing if arms" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_if_value",
        &params,
    );
    errdefer builder.deinit();
    const dst = builder.argument(0);
    const src = builder.argument(1);
    const index = try builder.globalId(.x);
    const value = try builder.load(src, index);
    const zero = try builder.constantFloat(.f32, 0.0);
    const positive = try builder.compare(.gt, value, zero);

    var if_op = try builder.if_(positive, &.{value.valueType()});
    const previous = builder.insertionBlock();
    builder.setInsertionBlock(if_op.thenBlock());
    const doubled = try builder.add(value, value);
    try builder.yield_(&.{doubled});
    builder.setInsertionBlock(if_op.elseBlock().?);
    try builder.yield_(&.{zero});
    builder.setInsertionBlock(previous);

    try builder.store(if_op.result(0).?, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_if_value", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "LIF_ELSE_") != null);
    try testing.expect(std.mem.indexOf(u8, text, "LIF_DONE_") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.global.f32") != null);
    try testing.expectEqual(std.mem.count(u8, text, "{"), std.mem.count(u8, text, "}"));
}

test "cuda choir ptx emitter lowers bool global load store as bytes" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i1),
        builder_mod.dynamicBuffer(.i1),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_bool_copy",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);
    const value = try builder.load(input, index);
    try builder.store(value, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_bool_copy", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "ld.global.u8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "setp.ne.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "selp.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.global.u8") != null);
}

test "cuda choir ptx emitter lowers bool select as predicates" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i1),
        builder_mod.dynamicBuffer(.i1),
        builder_mod.dynamicBuffer(.i1),
        builder_mod.dynamicBuffer(.i1),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_bool_select",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const mask = builder.argument(1);
    const lhs = builder.argument(2);
    const rhs = builder.argument(3);
    const index = try builder.globalId(.x);
    const cond = try builder.load(mask, index);
    const left = try builder.load(lhs, index);
    const right = try builder.load(rhs, index);
    const selected = try builder.select(cond, left, right);
    try builder.store(selected, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_bool_select", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "not.pred") != null);
    try testing.expect(std.mem.indexOf(u8, text, "and.pred") != null);
    try testing.expect(std.mem.indexOf(u8, text, "or.pred") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.global.u8") != null);
}

test "cuda choir ptx emitter lowers signed integer compare as signed" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_signed_compare",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);
    const value = try builder.load(input, index);
    const zero = try builder.constantInt(.i32, 0);
    const one = try builder.constantInt(.i32, 1);
    const pred = try builder.compare(.gt, value, zero);
    const selected = try builder.select(pred, one, zero);
    try builder.store(selected, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_signed_compare", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "setp.gt.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "setp.gt.u32") == null);
}

test "cuda choir ptx emitter lowers narrow integer storage with 32-bit compute" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i8),
        builder_mod.dynamicBuffer(.i8),
        builder_mod.dynamicBuffer(.u16),
        builder_mod.dynamicBuffer(.u16),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_narrow_int_ops",
        &params,
    );
    errdefer builder.deinit();
    const i8_out = builder.argument(0);
    const i8_input = builder.argument(1);
    const u16_out = builder.argument(2);
    const u16_input = builder.argument(3);
    const index = try builder.globalId(.x);

    const signed = try builder.load(i8_input, index);
    const signed_zero = try builder.constantInt(.i8, 0);
    const signed_two = try builder.constantInt(.i8, 2);
    const signed_sum = try builder.add(signed, signed_two);
    const signed_bounded = try builder.max(try builder.min(signed_sum, signed_two), signed_zero);
    const signed_positive = try builder.compare(.gt, signed, signed_zero);
    const signed_selected = try builder.select(signed_positive, signed_bounded, signed);
    try builder.store(signed_selected, i8_out, index);

    const unsigned = try builder.load(u16_input, index);
    const unsigned_one = try builder.constantInt(.u16, 1);
    const unsigned_two = try builder.constantInt(.u16, 2);
    const unsigned_sum = try builder.add(unsigned, unsigned_one);
    const unsigned_bounded = try builder.min(
        try builder.max(unsigned_sum, unsigned_one),
        unsigned_two,
    );
    const unsigned_positive = try builder.compare(.gt, unsigned, unsigned_one);
    const unsigned_selected = try builder.select(unsigned_positive, unsigned_bounded, unsigned);
    try builder.store(unsigned_selected, u16_out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_narrow_int_ops", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "ld.global.s8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.global.u8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "min.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "setp.gt.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ld.global.u16") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.global.u16") != null);
    try testing.expect(std.mem.indexOf(u8, text, "min.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "setp.gt.u32") != null);
}

test "cuda choir ptx emitter clamps signed indices before index cast" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_signed_index_clamp",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const data = builder.argument(1);
    const indices = builder.argument(2);
    const index = try builder.globalId(.x);
    const loaded = try builder.load(indices, index);
    const zero = try builder.constantInt(.i32, 0);
    const upper = try builder.constantInt(.i32, 5);
    const bounded = try builder.min(try builder.max(loaded, zero), upper);
    const source = try builder.castIndex(bounded);
    const value = try builder.load(data, source);
    try builder.store(value, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(
        testing.allocator,
        "accy_choir_test_signed_index_clamp",
        &program,
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "max.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "min.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max.u32") == null);
    try testing.expect(std.mem.indexOf(u8, text, "min.u32") == null);
}

test "cuda choir ptx emitter lowers i64 scalar operations" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i64),
        builder_mod.dynamicBuffer(.i64),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_i64_ops",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);

    const x = try builder.load(input, index);
    const zero = try builder.constantInt(.i64, 0);
    const two = try builder.constantInt(.i64, 2);
    const index_i64 = try builder.cast(index, .i64);
    const absolute = try builder.abs(x);
    const negated = try builder.neg(absolute);
    const product = try builder.mul(absolute, two);
    const quotient = try builder.div(product, two);
    const bounded = try builder.max(try builder.min(quotient, product), negated);
    const shifted = try builder.add(bounded, index_i64);
    const positive = try builder.compare(.gt, x, zero);
    const selected = try builder.select(positive, shifted, absolute);
    try builder.store(selected, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_i64_ops", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, ".reg .b64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ld.global.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mov.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cvt.u64.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "abs.s64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "neg.s64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mul.lo.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "div.s64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "min.s64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max.s64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "setp.gt.s64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "selp.b64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.global.u64") != null);
}

test "cuda choir ptx emitter lowers u64 scalar operations" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.u64),
        builder_mod.dynamicBuffer(.u64),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_u64_ops",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);

    const x = try builder.load(input, index);
    const zero = try builder.constantInt(.u64, 0);
    const two = try builder.constantInt(.u64, 2);
    const index_u64 = try builder.cast(index, .u64);
    const absolute = try builder.abs(x);
    const negated = try builder.neg(absolute);
    const product = try builder.mul(absolute, two);
    const quotient = try builder.div(product, two);
    const bounded = try builder.max(try builder.min(quotient, product), negated);
    const shifted = try builder.add(bounded, index_u64);
    const positive = try builder.compare(.gt, x, zero);
    const selected = try builder.select(positive, shifted, absolute);
    try builder.store(selected, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_u64_ops", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, ".reg .b64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ld.global.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mov.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cvt.u64.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "neg.s64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mul.lo.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "div.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "min.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "setp.gt.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "selp.b64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.global.u64") != null);
}

test "cuda choir ptx emitter lowers f64 scalar operations" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f64),
        builder_mod.dynamicBuffer(.f64),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_f64_ops",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);

    const x = try builder.load(input, index);
    const zero = try builder.constantFloat(.f64, 0.0);
    const two = try builder.constantFloat(.f64, 2.0);
    const index_f64 = try builder.cast(index, .f64);
    const absolute = try builder.abs(x);
    const negated = try builder.neg(absolute);
    const product = try builder.mul(absolute, two);
    const quotient = try builder.div(product, two);
    const bounded = try builder.max(try builder.min(quotient, product), negated);
    const shifted = try builder.add(bounded, index_f64);
    const positive = try builder.compare(.gt, x, zero);
    const selected = try builder.select(positive, shifted, absolute);
    try builder.store(selected, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_f64_ops", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, ".reg .f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ld.global.f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0d4000000000000000") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cvt.rn.f64.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "abs.f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "neg.f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mul.f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "div.rn.f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "min.f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max.f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "setp.gt.f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "selp.f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.global.f64") != null);
}

test "cuda choir ptx emitter lowers bf16 storage with f32 compute" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.bf16),
        builder_mod.dynamicBuffer(.bf16),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_bf16_ops",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);

    const x = try builder.load(input, index);
    const zero = try builder.constantFloat(.bf16, 0.0);
    const two = try builder.constantFloat(.bf16, 2.0);
    const index_bf16 = try builder.cast(index, .bf16);
    const absolute = try builder.abs(x);
    const negated = try builder.neg(absolute);
    const product = try builder.mul(absolute, two);
    const quotient = try builder.div(product, two);
    const bounded = try builder.max(try builder.min(quotient, product), negated);
    const shifted = try builder.add(bounded, index_bf16);
    const positive = try builder.compare(.gt, x, zero);
    const selected = try builder.select(positive, shifted, absolute);
    try builder.store(selected, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_bf16_ops", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "ld.global.b16      %r") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shl.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mov.b32            %f") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0f40000000") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cvt.rn.f32.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "abs.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "neg.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mul.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "div.approx.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "min.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "setp.gt.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "selp.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shr.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.global.b16") != null);
}

test "cuda choir ptx emitter lowers scalar math and bit operations" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_scalar_ops",
        &params,
    );
    errdefer builder.deinit();
    const f_out = builder.argument(0);
    const f_in = builder.argument(1);
    const i_out = builder.argument(2);
    const i_in = builder.argument(3);
    const index = try builder.globalId(.x);

    const x = try builder.load(f_in, index);
    const zero = try builder.constantFloat(.f32, 0.0);
    const two = try builder.constantFloat(.f32, 2.0);
    const abs_x = try builder.abs(x);
    const root = try builder.sqrt(abs_x);
    const s = try builder.sin(x);
    const c = try builder.cos(x);
    const t = try builder.tan(x);
    const floored = try builder.floor(x);
    const rounded = try builder.round(x);
    const truncated = try builder.trunc(x);
    const p = try builder.pow(abs_x, two);
    const angle = try builder.atan2(x, root);
    const fma = try builder.fma(s, c, root);
    const divided = try builder.div(fma, two);
    const sum = try builder.add(try builder.add(try builder.add(
        try builder.add(try builder.add(try builder.add(divided, t), p), angle),
        floored,
    ), rounded), truncated);
    const pred = try builder.compare(.gt, x, zero);
    const selected = try builder.select(pred, sum, abs_x);
    const bits = try builder.bitcast(selected, .i32);
    const roundtrip = try builder.bitcast(bits, .f32);
    try builder.store(roundtrip, f_out, index);

    const int_value = try builder.load(i_in, index);
    const one = try builder.constantInt(.i32, 1);
    const shl = try builder.shl(int_value, one);
    const shr = try builder.shr(int_value, one);
    const ushr = try builder.ushr(int_value, one);
    const anded = try builder.and_(shl, ushr);
    const ored = try builder.or_(anded, one);
    const xored = try builder.xor(ored, shr);
    const inverted = try builder.not(xored);
    const high = try builder.umulhi(inverted, int_value);

    const wide = try builder.cast(high, .i64);
    const wide_mask = try builder.constantInt(.i64, 0xFFFFFFFF);
    const wide_masked = try builder.and_(wide, wide_mask);
    const wide_square = try builder.mul(wide_masked, wide_masked);
    const wide_sum = try builder.add(wide_square, wide_masked);
    const wide_half = try builder.constantInt(.i64, 32);
    const wide_rot = try builder.or_(
        try builder.ushr(wide_sum, wide_half),
        try builder.shl(wide_sum, wide_half),
    );
    const wide_high = try builder.umulhi(wide_rot, wide_square);
    const narrowed = try builder.cast(wide_high, .i32);
    try builder.store(narrowed, i_out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_scalar_ops", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "div.approx.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "abs.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "sqrt.approx.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "sin.approx.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cos.approx.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cvt.rmi.f32.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0f3F000000") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cvt.rzi.f32.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "lg2.approx.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ex2.approx.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0f3F490FDB") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0f3FC90FDB") != null);
    try testing.expect(std.mem.indexOf(u8, text, "fma.rn.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "selp.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mov.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shl.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shr.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shr.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "and.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "or.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "xor.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mul.hi.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cvt.s64.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "and.b64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mul.lo.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shl.b64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shr.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "or.b64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mul.hi.u64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cvt.u32.u64") != null);
}

test "cuda choir ptx emitter lowers warp control intrinsics" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_warp_ops",
        &params,
    );
    errdefer builder.deinit();
    const i_out = builder.argument(0);
    const f_out = builder.argument(1);
    const f_in = builder.argument(2);
    const index = try builder.globalId(.x);

    const lane = try builder.laneId();
    _ = try builder.warpId();
    _ = try builder.activeMask();
    const lane_i32 = try builder.cast(lane, .i32);
    const zero = try builder.constantInt(.i32, 0);
    const one = try builder.constantInt(.i32, 1);
    const is_lane_zero = try builder.compare(.eq, lane_i32, zero);
    const all = try builder.allSync(is_lane_zero);
    const any = try builder.anySync(is_lane_zero);
    const ballot = try builder.ballotSync(is_lane_zero);
    const shuffled_lane = try builder.shuffleSync(.xor, lane_i32, one);
    const all_i32 = try builder.cast(all, .i32);
    const any_i32 = try builder.cast(any, .i32);
    const folded_vote = try builder.xor(try builder.xor(ballot, all_i32), any_i32);
    const folded = try builder.xor(folded_vote, shuffled_lane);
    try builder.store(folded, i_out, index);

    const x = try builder.load(f_in, index);
    const shuffled_x = try builder.shuffleSync(.down, x, one);
    try builder.store(shuffled_x, f_out, index);
    try builder.syncWarp();
    try builder.barrier(.warp);
    try builder.barrier(.block);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_warp_ops", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, ".version 6.2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "%laneid") != null);
    try testing.expect(std.mem.indexOf(u8, text, "%warpid") == null);
    try testing.expect(std.mem.indexOf(u8, text, "%tid.z") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shr.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "activemask.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "vote.sync.all.pred") != null);
    try testing.expect(std.mem.indexOf(u8, text, "vote.sync.any.pred") != null);
    try testing.expect(std.mem.indexOf(u8, text, "vote.sync.ballot.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "selp.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shfl.sync.bfly.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shfl.sync.down.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "bar.warp.sync") != null);
    try testing.expect(std.mem.indexOf(u8, text, "bar.sync") != null);
}

test "cuda choir ptx emitter lowers warp reductions and scans" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f64),
        builder_mod.dynamicBuffer(.f64),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_warp_collectives",
        &params,
    );
    errdefer builder.deinit();
    const i_out = builder.argument(0);
    const i_in = builder.argument(1);
    const f_out = builder.argument(2);
    const f_in = builder.argument(3);
    const d_out = builder.argument(4);
    const d_in = builder.argument(5);
    const index = try builder.globalId(.x);

    const int_value = try builder.load(i_in, index);
    const int_reduce = try builder.warpReduce(.add, int_value);
    const int_scan = try builder.warpScan(.xor, .inclusive, int_value);
    const int_folded = try builder.xor(int_reduce, int_scan);
    try builder.store(int_folded, i_out, index);

    const float_value = try builder.load(f_in, index);
    const float_reduce = try builder.warpReduce(.max, float_value);
    const float_scan = try builder.warpScan(.add, .exclusive, float_value);
    const float_folded = try builder.add(float_reduce, float_scan);
    try builder.store(float_folded, f_out, index);

    const double_value = try builder.load(d_in, index);
    const double_reduce = try builder.warpReduce(.add, double_value);
    try builder.store(double_reduce, d_out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(
        testing.allocator,
        "accy_choir_test_warp_collectives",
        &program,
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "shfl.sync.bfly.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shfl.sync.up.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0x0, %r") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@%p") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mov.b64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add.f64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "xor.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0f00000000") != null);
}

test "cuda prefix sum scan uses safe shared base index" {
    const testing = std.testing;
    const scan = accy.kernel.library.scan;
    const instance = scan.PrefixSum{ .extent = 64, .threads = 64 };
    const entry_name = try scan.prefixSumFamilyEntryName(testing.allocator, instance);
    defer testing.allocator.free(entry_name);

    var graph = try scan.PrefixSumRuntimeFamilyF32.buildNamed(
        testing.allocator,
        scan.PrefixSumRuntimeFamilyF32.Limits.standard,
        entry_name,
        instance,
    );
    defer graph.deinit();
    const text = try emitLoweredPtx(testing.allocator, entry_name, &graph);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "ld.shared.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "selp.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max.u32") == null);
}

test "cuda segment sum clamps signed offsets before index cast" {
    const testing = std.testing;
    const segmented = accy.kernel.library.segmented;
    const instance = segmented.SegmentSum{ .segments = 8, .total = 80, .threads = 64 };
    const entry_name = try segmented.segmentSumFamilyEntryName(testing.allocator, instance);
    defer testing.allocator.free(entry_name);

    var graph = try segmented.SegmentSumRuntimeFamilyF32.buildNamed(
        testing.allocator,
        segmented.SegmentSumRuntimeFamilyF32.Limits.standard,
        entry_name,
        instance,
    );
    defer graph.deinit();
    const text = try emitLoweredPtx(testing.allocator, entry_name, &graph);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "max.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "min.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max.u32") == null);
}

test "cuda choir ptx emitter lowers shared memory" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_shared_memory",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);
    const lane = try builder.laneId();
    const shared = try builder.sharedBuffer(.f32, 32);

    const x = try builder.load(input, index);
    try builder.store(x, shared, lane);
    try builder.barrier(.block);
    const y = try builder.load(shared, lane);
    try builder.store(y, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_shared_memory", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, ".shared .align 16 .b8 __choir_shared") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.shared.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ld.shared.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "bar.sync") != null);
}

test "cuda choir ptx emitter lowers dynamic shared memory offsets" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_dynamic_shared_memory",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);
    const lane = try builder.laneId();
    const first = try builder.dynamicSharedBuffer(.f32, 4, 0);
    const second = try builder.dynamicSharedBuffer(.f32, 4, 64);

    const x = try builder.load(input, index);
    try builder.store(x, first, lane);
    try builder.store(x, second, lane);
    try builder.barrier(.block);
    const y = try builder.load(second, lane);
    try builder.store(y, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(
        testing.allocator,
        "accy_choir_test_dynamic_shared_memory",
        &program,
    );
    defer testing.allocator.free(text);

    try testing.expect(
        std.mem.indexOf(u8, text, ".extern .shared .align 16 .b8 __choir_dynamic_shared[]") != null,
    );
    try testing.expect(std.mem.indexOf(u8, text, ".shared .align 16 .b8 __choir_shared") == null);
    try testing.expect(std.mem.indexOf(u8, text, "mov.u32            %r") != null);
    try testing.expect(std.mem.indexOf(u8, text, "__choir_dynamic_shared") != null);
    try testing.expect(std.mem.indexOf(u8, text, "+64]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "st.shared.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ld.shared.f32") != null);
}

test "cuda choir ptx emitter lowers global atomics" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_atomics",
        &params,
    );
    errdefer builder.deinit();
    const f_bins = builder.argument(0);
    const i_bins = builder.argument(1);
    const index = try builder.globalId(.x);
    const f_delta = try builder.constantFloat(.f32, 1.5);
    const i_zero = try builder.constantInt(.i32, 0);
    const i_one = try builder.constantInt(.i32, 1);
    const i_three = try builder.constantInt(.i32, 3);

    _ = try builder.atomicRmw(.add, f_delta, f_bins, index);
    const old_add = try builder.atomicRmw(.add, i_one, i_bins, index);
    const old_min = try builder.atomicRmw(.min, old_add, i_bins, index);
    const old_max = try builder.atomicRmw(.max, old_min, i_bins, index);
    const old_and = try builder.atomicRmw(.bit_and, old_max, i_bins, index);
    const old_or = try builder.atomicRmw(.bit_or, old_and, i_bins, index);
    const old_xor = try builder.atomicRmw(.bit_xor, old_or, i_bins, index);
    _ = try builder.atomicCas(i_zero, i_three, i_bins, index);
    _ = try builder.atomicRmw(.exchange, old_xor, i_bins, index);
    _ = try builder.atomicRmw(.bit_or, i_one, i_bins, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_atomics", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "red.global.add.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.global.add.f32") == null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.global.add.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.global.min.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.global.max.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.global.and.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.global.or.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.global.xor.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.global.cas.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.global.exch.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "red.global.or.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "red.global.exch") == null);
}

test "cuda choir ptx emitter lowers shared atomics" {
    const testing = std.testing;
    const builder_mod = accy.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_shared_atomics",
        &params,
    );
    errdefer builder.deinit();
    const i_out = builder.argument(0);
    const f_out = builder.argument(1);
    const index = try builder.globalId(.x);
    const i_bins = try builder.sharedBuffer(.i32, 16);
    const f_bins = try builder.sharedBuffer(.f32, 16);
    const slot = try builder.constantIndex(0);
    const i_one = try builder.constantInt(.i32, 1);
    const i_three = try builder.constantInt(.i32, 3);
    const f_delta = try builder.constantFloat(.f32, 0.5);

    const old_add = try builder.atomicRmw(.add, i_one, i_bins, slot);
    _ = try builder.atomicRmw(.max, old_add, i_bins, slot);
    _ = try builder.atomicCas(i_one, i_three, i_bins, slot);
    const f_old = try builder.atomicRmw(.add, f_delta, f_bins, slot);
    try builder.barrier(.block);
    const merged = try builder.atomicRmw(.add, old_add, i_out, index);
    _ = merged;
    try builder.store(f_old, f_out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitLoweredPtx(testing.allocator, "accy_choir_test_shared_atomics", &program);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "atom.shared.add.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "red.shared.max.s32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.shared.cas.b32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.shared.add.f32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "red.global.add.u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atom.global.add.u32") == null);
    try testing.expect(std.mem.indexOf(u8, text, "bar.sync") != null);
}
