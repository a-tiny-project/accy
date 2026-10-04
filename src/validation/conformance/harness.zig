const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const pretty = @import("pretty");
const accy = @import("accy");
const choir = @import("choir");
const sys = @import("sys");
const ptx = @import("accy_validation_ptx");
const conformance = @import("root.zig");

const records = conformance.records;
const kernel = accy.kernel;

pub const CudaState = gpu.cuda.State;
pub const MetalState = gpu.metal.State;
pub const VulkanState = gpu.vulkan.State;
pub const BackendHandle = gpu.BackendHandle;
pub const SemanticBuilder = accy.choir.SemanticBuilder;
pub const SemanticModule = accy.choir.SemanticModule;
pub const FunctionBuilder = accy.choir.semantic.FunctionBuilder;
pub const Value = choir.ir.Value;
pub const DType = gpu_abi.DType;
pub const Bf16 = gpu_abi.Bf16;

pub const Expectation = enum { verified, unsupported, invalid };

pub const Mode = enum { execute, assemble };

pub const Assembler = struct {
    dir: []const u8,
    target: []const u8,
};

pub const Gate = struct {
    mode: Mode,
    assembler: ?Assembler,
};

pub const Tensor = struct {
    dtype: DType,
    dims: []const i64,

    pub fn elementCount(comptime self: Tensor) usize {
        var count: usize = 1;
        for (self.dims) |dim| count *= @as(usize, @intCast(dim));
        return count;
    }

    pub fn byteCount(comptime self: Tensor) usize {
        return self.elementCount() * self.dtype.sizeOf();
    }
};

pub fn vec(comptime dtype: DType, comptime len: i64) Tensor {
    return .{ .dtype = dtype, .dims = &.{len} };
}

pub fn mat(comptime dtype: DType, comptime rows: i64, comptime cols: i64) Tensor {
    return .{ .dtype = dtype, .dims = &.{ rows, cols } };
}

pub fn requiredDTypes(comptime Spec: type) gpu.DTypeSet {
    var set: gpu.DTypeSet = .{};
    if (comptime @hasDecl(Spec, "buffers")) {
        inline for (Spec.buffers) |buffer| set.insert(buffer.tensor.dtype);
    } else {
        inline for (Spec.inputs) |input| set.insert(input.dtype);
        set.insert(Spec.output.dtype);
    }
    return set;
}

pub fn requiredFeatures(comptime Spec: type) gpu_abi.Features {
    if (comptime @hasDecl(Spec, "required_features")) return Spec.required_features;
    return .{};
}

pub fn requiredSubgroup(comptime Spec: type) gpu_abi.SubgroupRequirements {
    if (comptime @hasDecl(Spec, "required_subgroup")) return Spec.required_subgroup;
    return .{};
}

pub fn buildModule(comptime Spec: type, allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    defer builder.deinit();

    var param_types: [Spec.inputs.len]choir.ir.Type = undefined;
    inline for (Spec.inputs, 0..) |input, index| {
        param_types[index] = try builder.tensor(input.dtype, input.dims);
    }
    const result_type = try builder.tensor(Spec.output.dtype, Spec.output.dims);

    var function = try builder.beginFunction(
        "conformance_" ++ Spec.name,
        &param_types,
        &.{result_type},
    );
    const result = try Spec.body(&builder, &function);
    try function.return_(&.{result});
    try function.finish();
    return try builder.finish();
}

pub fn runCase(
    comptime Spec: type,
    allocator: std.mem.Allocator,
    handle: BackendHandle,
    gate: Gate,
) !records.Case {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const compile_start = nowNs();
    const module = try buildModule(Spec, allocator);
    var prepared = try accy.executable.prepareFragmentFromSemanticModule(
        allocator,
        handle,
        module,
        .{},
    );
    defer prepared.deinit();
    const artifact_module = try accy.executable.createArtifactJobFromPreparedJob(
        allocator,
        handle,
        &prepared,
        .{},
    );
    defer artifact_module.deinit();

    const ptxas_status = acceptPlannedKernels(allocator, artifact_module, gate.assembler);
    const ptxas_ok = !std.mem.eql(u8, ptxas_status, "fail");

    if (gate.mode == .assemble) {
        return .{
            .name = Spec.name,
            .status = if (ptxas_ok) "assembled" else "fail",
            .detail = if (ptxas_ok) "" else "PtxasRejected",
            .ptxas = ptxas_status,
            .kernels = artifact_module.kernelCount(),
            .compile_ns = elapsedNs(compile_start),
            .launch_read_ns = 0,
            .checksum = 0,
            .max_abs_error = 0,
            .tolerance = Spec.tolerance,
        };
    }

    const compiled = try accy.executable.compileFragmentFromArtifactJob(allocator, artifact_module);
    var fragment = try accy.executable.loadFragment(allocator, handle, compiled, .{});
    const compile_ns = elapsedNs(compile_start);
    defer fragment.deinit();

    var input_views: [Spec.inputs.len][]const u8 = undefined;
    inline for (Spec.inputs, 0..) |input, index| {
        const buffer = try arena.alignedAlloc(u8, .@"16", input.byteCount());
        fillInput(Spec, input, index, buffer);
        input_views[index] = buffer;
    }

    const output_bytes = try arena.alignedAlloc(u8, .@"16", Spec.output.byteCount());
    @memset(output_bytes, 0xA5);
    var outputs = [_][]u8{output_bytes};

    const launch_start = nowNs();
    try accy.executable.invoke(fragment, allocator, allocator, &input_views, &outputs);
    const launch_read_ns = elapsedNs(launch_start);

    const expected = try arena.alignedAlloc(u8, .@"16", Spec.output.byteCount());
    try expectedOutput(
        Spec,
        allocator,
        &prepared,
        artifact_module.artifactPlan(),
        &input_views,
        expected,
    );

    const max_error = maxAbsError(Spec.output.dtype, expected, output_bytes);
    const numeric_ok = fragment.outputCount() == 1 and max_error <= Spec.tolerance;
    return .{
        .name = Spec.name,
        .status = if (numeric_ok and ptxas_ok) "pass" else "fail",
        .detail = if (ptxas_ok) "" else "PtxasRejected",
        .ptxas = ptxas_status,
        .kernels = fragment.kernelCount(),
        .compile_ns = compile_ns,
        .launch_read_ns = launch_read_ns,
        .checksum = finiteOrMax(checksum(Spec.output.dtype, output_bytes)),
        .max_abs_error = finiteOrMax(max_error),
        .tolerance = Spec.tolerance,
    };
}

fn acceptPlannedKernels(
    allocator: std.mem.Allocator,
    artifact_module: *accy.artifact.ArtifactJob,
    assembler: ?Assembler,
) []const u8 {
    const active = assembler orelse return "skip";
    const plan = artifact_module.artifactPlan();
    for (plan.kernels.items) |planned| {
        ptx.assemble.acceptArtifact(allocator, active.dir, active.target, planned.artifact) catch {
            return "fail";
        };
    }
    return "pass";
}

fn expectedOutput(
    comptime Spec: type,
    allocator: std.mem.Allocator,
    prepared: *accy.preparation.BackendPreparedJob,
    artifact_plan: *const accy.artifact.BackendArtifactPlan,
    input_views: *const [Spec.inputs.len][]const u8,
    output_bytes: []u8,
) !void {
    if (comptime Spec.expectation == .verified) {
        try expectedOutputFromGeneratedKernel(
            Spec,
            allocator,
            prepared,
            artifact_plan,
            input_views,
            output_bytes,
        );
        return;
    }
    Spec.reference(input_views, output_bytes);
}

fn expectedOutputFromGeneratedKernel(
    comptime Spec: type,
    allocator: std.mem.Allocator,
    prepared: *accy.preparation.BackendPreparedJob,
    artifact_plan: *const accy.artifact.BackendArtifactPlan,
    input_views: *const [Spec.inputs.len][]const u8,
    output_bytes: []u8,
) !void {
    const product = @constCast(try prepared.kernelizationProduct());
    if (product.kernelCount() != artifact_plan.kernelCount()) return error.UnsupportedOperation;
    var slots = try OracleSlotTable.init(Spec, allocator, artifact_plan, input_views, output_bytes);
    defer slots.deinit();

    for (artifact_plan.kernels.items, 0..) |planned, kernel_index| {
        if (planned.runtime_scalar_argument_count != 0 or planned.static_arguments.len != 0) {
            return error.UnsupportedOperation;
        }
        var generated = &product.kernels.items[kernel_index].program;
        const params = generated.params();
        const has_count_argument = planned.element_count_argument != .none;
        const expected_arg_count = 1 +
            planned.input_slot_ids.len + @intFromBool(has_count_argument);
        if (params.len != expected_arg_count) return error.UnsupportedOperation;

        const args = try allocator.alloc(kernel.Argument, params.len);
        defer allocator.free(args);
        var arg_index: usize = 0;
        args[arg_index] = .{ .memref = try slots.bytesFor(planned.output_slot_id) };
        arg_index += 1;

        for (planned.input_slot_ids) |slot_id| {
            args[arg_index] = .{ .memref = try slots.bytesFor(slot_id) };
            arg_index += 1;
        }

        var count = [_]i32{std.math.cast(i32, planned.element_count) orelse return error.Overflow};
        if (has_count_argument) {
            switch (params[arg_index]) {
                .buffer => args[arg_index] = kernel.argumentBuffer(i32, count[0..]),
                .scalar => |dtype| args[arg_index] = switch (dtype) {
                    .i32 => kernel.argumentI32(count[0]),
                    .i64 => kernel.argumentI64(count[0]),
                    else => return error.UnsupportedOperation,
                },
            }
            arg_index += 1;
        }

        if (arg_index != args.len) return error.UnsupportedOperation;
        var executor = kernel.program.execution.Executor.init(generated);
        defer executor.deinit();
        try executor.runCpu(allocator, args);
    }
}

const OracleSlot = struct {
    slot_id: usize,
    bytes: []u8,
    owned: bool,
};

const OracleSlotTable = struct {
    allocator: std.mem.Allocator,
    items: []OracleSlot,

    fn init(
        comptime Spec: type,
        allocator: std.mem.Allocator,
        artifact_plan: *const accy.artifact.BackendArtifactPlan,
        input_views: *const [Spec.inputs.len][]const u8,
        output_bytes: []u8,
    ) !OracleSlotTable {
        if (artifact_plan.output_slot_ids.len != 1) return error.UnsupportedOperation;
        const items = try allocator.alloc(OracleSlot, artifact_plan.slots.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| {
                if (item.owned) allocator.free(item.bytes);
            }
            allocator.free(items);
        }

        for (artifact_plan.slots) |slot| {
            items[initialized] = try slotBytes(
                Spec,
                allocator,
                artifact_plan,
                input_views,
                output_bytes,
                slot,
            );
            initialized += 1;
        }

        return .{ .allocator = allocator, .items = items };
    }

    fn deinit(self: *OracleSlotTable) void {
        for (self.items) |item| {
            if (item.owned) self.allocator.free(item.bytes);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }

    fn bytesFor(self: *const OracleSlotTable, slot_id: usize) ![]u8 {
        for (self.items) |item| {
            if (item.slot_id == slot_id) return item.bytes;
        }
        return error.InvalidArtifact;
    }
};

fn slotBytes(
    comptime Spec: type,
    allocator: std.mem.Allocator,
    artifact_plan: *const accy.artifact.BackendArtifactPlan,
    input_views: *const [Spec.inputs.len][]const u8,
    output_bytes: []u8,
    slot: accy.artifact.PlannedSlot,
) !OracleSlot {
    if (slot.slot_id == artifact_plan.output_slot_ids[0]) {
        return .{ .slot_id = slot.slot_id, .bytes = output_bytes, .owned = false };
    }
    if (boundaryInputBytes(Spec, artifact_plan, input_views, slot.slot_id)) |bytes| {
        return .{ .slot_id = slot.slot_id, .bytes = @constCast(bytes), .owned = false };
    }
    if (slot.constantBytes()) |bytes| {
        return .{ .slot_id = slot.slot_id, .bytes = @constCast(bytes), .owned = false };
    }
    const byte_size_u64 = slot.byte_size orelse return error.UnsupportedOperation;
    const byte_size = std.math.cast(usize, byte_size_u64) orelse return error.InvalidArtifact;
    const bytes = try allocator.alloc(u8, byte_size);
    @memset(bytes, 0xA5);
    return .{ .slot_id = slot.slot_id, .bytes = bytes, .owned = true };
}

fn boundaryInputBytes(
    comptime Spec: type,
    artifact_plan: *const accy.artifact.BackendArtifactPlan,
    input_views: *const [Spec.inputs.len][]const u8,
    slot_id: usize,
) ?[]const u8 {
    if (comptime Spec.inputs.len == 0) return null;
    for (artifact_plan.input_slot_ids, 0..) |input_slot_id, index| {
        if (input_slot_id == slot_id) return input_views[index];
    }
    return null;
}

pub fn finiteOrMax(value: f32) f32 {
    return if (std.math.isFinite(value)) value else std.math.floatMax(f32);
}

fn fillInput(
    comptime Spec: type,
    comptime input: Tensor,
    comptime index: usize,
    buffer: []u8,
) void {
    if (@hasDecl(Spec, "fill")) {
        Spec.fill(index, buffer);
        return;
    }
    defaultFill(input.dtype, index, buffer);
}

pub fn defaultFill(comptime dtype: DType, input_index: usize, buffer: []u8) void {
    const T = dtype.ZigType();
    const values = std.mem.bytesAsSlice(T, buffer);
    for (values, 0..) |*value, element_index| {
        value.* = defaultValue(T, input_index, element_index);
    }
}

pub fn positiveFill(comptime dtype: DType, input_index: usize, buffer: []u8) void {
    const T = dtype.ZigType();
    const values = std.mem.bytesAsSlice(T, buffer);
    for (values, 0..) |*value, element_index| {
        value.* = positiveValue(T, input_index, element_index);
    }
}

pub fn defaultValue(comptime T: type, input_index: usize, element_index: usize) T {
    const pattern = (element_index * 7 + input_index * 13 + 5) % 31;
    const alt = (element_index * 11 + input_index * 3 + 1) % 29;
    if (comptime T == Bf16) return Bf16.fromF32(defaultValue(f32, input_index, element_index));
    return switch (@typeInfo(T)) {
        .bool => ((pattern + alt) & 1) == 0,
        .float => blk: {
            const base: f32 = -0.45 + @as(f32, @floatFromInt(pattern)) * 0.03125;
            const tweak: f32 = @as(f32, @floatFromInt(alt)) * 0.001;
            break :blk @floatCast(base + tweak);
        },
        .int => |info| if (info.signedness == .signed)
            if (info.bits < 32)
                @intCast(@as(i64, @intCast((pattern * 3 + alt) % 63)) - 31)
            else
                @intCast(@as(i64, @intCast(pattern * 7 + alt)) - 100)
        else
            @intCast(pattern * 7 + alt),
        else => @compileError("unsupported conformance element type"),
    };
}

pub fn positiveValue(comptime T: type, input_index: usize, element_index: usize) T {
    const pattern = (element_index * 7 + input_index * 13 + 5) % 31;
    if (comptime T == Bf16) return Bf16.fromF32(positiveValue(f32, input_index, element_index));
    return switch (@typeInfo(T)) {
        .bool => pattern != 0,
        .float => @floatCast(0.0625 + @as(f32, @floatFromInt(pattern)) * 0.0625),
        .int => @intCast(pattern + 1),
        else => @compileError("unsupported conformance element type"),
    };
}

pub fn maxAbsError(comptime dtype: DType, expected: []const u8, actual: []const u8) f32 {
    const T = dtype.ZigType();
    const expected_values = std.mem.bytesAsSlice(T, expected);
    const actual_values = std.mem.bytesAsSlice(T, actual);
    var max: f32 = 0;
    for (expected_values, actual_values) |want, got| {
        max = @max(max, errorOf(T, want, got));
    }
    return max;
}

fn errorOf(comptime T: type, want: T, got: T) f32 {
    if (comptime T == Bf16) {
        const w = want.toF32();
        const g = got.toF32();
        if (std.math.isNan(w) and std.math.isNan(g)) return 0;
        if (std.math.isNan(w) or std.math.isNan(g)) return std.math.inf(f32);
        return @abs(w - g);
    }
    switch (@typeInfo(T)) {
        .bool => return if (want == got) 0 else 1,
        .float => {
            const w: f32 = @floatCast(want);
            const g: f32 = @floatCast(got);
            if (std.math.isNan(w) and std.math.isNan(g)) return 0;
            if (std.math.isNan(w) or std.math.isNan(g)) return std.math.inf(f32);
            return @abs(w - g);
        },
        .int => {
            if (comptime @typeInfo(T).int.signedness == .unsigned) {
                const w: u128 = @intCast(want);
                const g: u128 = @intCast(got);
                return @floatFromInt(if (w > g) w - g else g - w);
            }
            const w: i128 = @intCast(want);
            const g: i128 = @intCast(got);
            return @floatFromInt(if (w > g) w - g else g - w);
        },
        else => @compileError("unsupported conformance element type"),
    }
}

pub fn checksum(comptime dtype: DType, bytes: []const u8) f32 {
    const T = dtype.ZigType();
    const values = std.mem.bytesAsSlice(T, bytes);
    var sum: f64 = 0;
    for (values) |value| {
        if (comptime T == Bf16) {
            sum += value.toF32();
            continue;
        }
        sum += switch (@typeInfo(T)) {
            .bool => if (value) 1 else 0,
            .float => @as(f64, @floatCast(value)),
            .int => @as(f64, @floatFromInt(value)),
            else => @compileError("unsupported conformance element type"),
        };
    }
    return @floatCast(sum);
}

pub fn numericToF32(comptime T: type, value: T) f32 {
    if (comptime T == Bf16) return value.toF32();
    return switch (@typeInfo(T)) {
        .bool => if (value) 1 else 0,
        .float => @floatCast(value),
        .int => @floatFromInt(value),
        else => @compileError("unsupported conformance element type"),
    };
}

pub fn nowNs() i128 {
    return sys.time.nanoTimestamp();
}

pub fn elapsedNs(start: i128) u64 {
    const elapsed = nowNs() - start;
    if (elapsed <= 0) return 0;
    return @intCast(elapsed);
}

test "default fill is deterministic and mixes input positions" {
    var first: [64]u8 = undefined;
    var second: [64]u8 = undefined;
    var other: [64]u8 = undefined;
    defaultFill(.f32, 0, first[0..]);
    defaultFill(.f32, 0, second[0..]);
    defaultFill(.f32, 1, other[0..]);
    try std.testing.expectEqualSlices(u8, first[0..], second[0..]);
    try std.testing.expect(!std.mem.eql(u8, first[0..], other[0..]));
}

test "positive fill stays strictly positive" {
    var buffer: [128]u8 = undefined;
    positiveFill(.f32, 0, buffer[0..]);
    const values = std.mem.bytesAsSlice(f32, buffer[0..]);
    for (values) |value| try std.testing.expect(value > 0);
}

test "max abs error treats mismatched nan as infinite" {
    const want = [_]f32{ 1.0, std.math.nan(f32) };
    const got_match = [_]f32{ 1.0, std.math.nan(f32) };
    const got_bad = [_]f32{ 1.0, 0.0 };
    try std.testing.expectEqual(
        @as(f32, 0),
        maxAbsError(.f32, std.mem.sliceAsBytes(want[0..]), std.mem.sliceAsBytes(got_match[0..])),
    );
    try std.testing.expect(std.math.isInf(
        maxAbsError(.f32, std.mem.sliceAsBytes(want[0..]), std.mem.sliceAsBytes(got_bad[0..])),
    ));
}

test "integer error is the absolute difference" {
    const want = [_]i32{ 5, -7 };
    const got = [_]i32{ 5, -10 };
    try std.testing.expectEqual(
        @as(f32, 3),
        maxAbsError(.i32, std.mem.sliceAsBytes(want[0..]), std.mem.sliceAsBytes(got[0..])),
    );
}

test "conformance semantic row required dtypes include inputs and output" {
    const Spec = struct {
        pub const name = "dtype_requirements_semantic";
        pub const expectation: Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const inputs = [_]Tensor{
            vec(.f16, 4),
            vec(.i32, 4),
        };
        pub const output = vec(.f32, 4);
    };

    const set = requiredDTypes(Spec);
    try std.testing.expect(set.contains(.f16));
    try std.testing.expect(set.contains(.i32));
    try std.testing.expect(set.contains(.f32));
    try std.testing.expect(!set.contains(.bf16));
}

test "conformance family row required dtypes include every buffer" {
    const Spec = struct {
        pub const name = "dtype_requirements_family";
        pub const expectation: Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const buffers = [_]FamilyBuffer{
            .{ .tensor = vec(.bf16, 4), .access = .inout },
            .{ .tensor = vec(.u32, 4) },
        };
    };

    const set = requiredDTypes(Spec);
    try std.testing.expect(set.contains(.bf16));
    try std.testing.expect(set.contains(.u32));
    try std.testing.expect(!set.contains(.f32));
}

test "conformance row backend requirements default to empty" {
    const Spec = struct {
        pub const name = "empty_backend_requirements";
        pub const expectation: Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const inputs = [_]Tensor{vec(.f32, 4)};
        pub const output = vec(.f32, 4);
    };

    try std.testing.expect(std.meta.eql(gpu_abi.Features{}, requiredFeatures(Spec)));
    try std.testing.expect(std.meta.eql(gpu_abi.SubgroupRequirements{}, requiredSubgroup(Spec)));
}

test "conformance row backend requirements read optional declarations" {
    const Spec = struct {
        pub const name = "declared_backend_requirements";
        pub const expectation: Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const inputs = [_]Tensor{vec(.f32, 4)};
        pub const output = vec(.f32, 4);
        pub const required_features = gpu_abi.Features{ .atomic_f32_add_device = true };
        pub const required_subgroup = gpu_abi.SubgroupRequirements{
            .supported = true,
            .scan = true,
        };
    };

    try std.testing.expect(requiredFeatures(Spec).atomic_f32_add_device);
    try std.testing.expect(requiredSubgroup(Spec).supported);
    try std.testing.expect(requiredSubgroup(Spec).scan);
}

fn expectGeneratedOracleMatchesReference(comptime Spec: type) !void {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };

    const module = try buildModule(Spec, allocator);
    var prepared = try accy.executable.prepareFragmentFromSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    defer prepared.deinit();

    var input_views: [Spec.inputs.len][]const u8 = undefined;
    var input_buffers: [Spec.inputs.len][]align(16) u8 = undefined;
    inline for (Spec.inputs, 0..) |input, index| {
        const buffer = try allocator.alignedAlloc(u8, .@"16", input.byteCount());
        fillInput(Spec, input, index, buffer);
        input_views[index] = buffer;
        input_buffers[index] = buffer;
    }
    defer {
        inline for (0..Spec.inputs.len) |index| allocator.free(input_buffers[index]);
    }

    const oracle = try allocator.alignedAlloc(u8, .@"16", Spec.output.byteCount());
    defer allocator.free(oracle);
    const reference = try allocator.alignedAlloc(u8, .@"16", Spec.output.byteCount());
    defer allocator.free(reference);

    const artifact_module = try accy.executable.createArtifactJobFromPreparedJob(
        allocator,
        state.handle(),
        &prepared,
        .{},
    );
    defer artifact_module.deinit();

    try expectedOutput(
        Spec,
        allocator,
        &prepared,
        artifact_module.artifactPlan(),
        &input_views,
        oracle,
    );
    Spec.reference(&input_views, reference);
    try std.testing.expect(maxAbsError(Spec.output.dtype, reference, oracle) <= Spec.tolerance);
}

test "conformance verified references match the generated CPU oracle" {
    @setEvalBranchQuota(200_000);
    inline for (conformance.cases.all) |Spec| {
        if (comptime std.mem.eql(u8, Spec.name, "add_f32_256") or
            std.mem.eql(u8, Spec.name, "add_f16_256") or
            std.mem.eql(u8, Spec.name, "reshape_add_f32_4x32") or
            std.mem.eql(u8, Spec.name, "reduce_sum_f32_16x16") or
            std.mem.eql(u8, Spec.name, "dot_general_f32_16x16") or
            std.mem.eql(u8, Spec.name, "pad_f32_6x6") or
            std.mem.eql(u8, Spec.name, "pad_i1_6x6"))
        {
            try expectGeneratedOracleMatchesReference(Spec);
        }
    }
}

test "conformance harness executes selected cases on live Metal" {
    @setEvalBranchQuota(200_000);
    const allocator = std.testing.allocator;
    var state = try initMetalStateOrSkip(allocator);
    defer state.deinit();
    const gate = Gate{ .mode = .execute, .assembler = null };

    var semantic_count: usize = 0;
    var family_count: usize = 0;
    inline for (conformance.cases.all) |Spec| {
        if (comptime selectedMetalConformanceCase(Spec)) {
            const result = if (comptime @hasDecl(Spec, "buildArtifact"))
                runFamilyCase(Spec, allocator, state.handle(), gate) catch |err| {
                    pretty.diagnostic.writeStderrText(
                        "metal conformance case errored: name={s} error={s}\n",
                        .{ Spec.name, @errorName(err) },
                    );
                    return err;
                }
            else
                runCase(Spec, allocator, state.handle(), gate) catch |err| {
                    pretty.diagnostic.writeStderrText(
                        "metal conformance case errored: name={s} error={s}\n",
                        .{ Spec.name, @errorName(err) },
                    );
                    return err;
                };
            try expectConformanceCasePass(result);
            if (comptime @hasDecl(Spec, "buildArtifact")) {
                family_count += 1;
            } else {
                semantic_count += 1;
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 94), semantic_count);
    try std.testing.expectEqual(
        @as(usize, selected_metal_family_conformance_cases.len),
        family_count,
    );
}

const selected_metal_family_conformance_cases = [_][]const u8{
    "gather_family_f32_2x5x6x3",
    "gather_family_f16_2x5x6x3",
    "scatter_family_f32_2x5x6x3",
    "scatter_family_f16_2x5x6x3",
    "scatter_add_family_direct_i32_16x64",
    "scatter_add_family_shared_i32_16x64",
    "scatter_add_family_direct_f32_16x64",
    "prefix_sum_family_inclusive_f32_64",
    "prefix_sum_family_exclusive_f32_64",
    "segment_sum_family_thread_f32_8x80",
    "segment_sum_family_warp_f32_8x80",
    "filter_family_nonzero_f32_70x32",
    "filter_family_greater_i32_40x32",
    "device_scan_block_scan_family_dst_f32_3x32",
    "device_scan_block_scan_family_sums_f32_3x32",
    "device_scan_block_scan_family_dst_f16_3x32",
    "device_scan_block_scan_family_sums_f16_3x32",
    "device_scan_add_base_family_f32_3x32",
    "device_scan_add_base_family_f16_3x32",
    "batched_cholesky_family_f32_48x3",
    "batched_cholesky_family_f32_48x3_interleaved",
    "batched_cholesky_solve_family_f32_48x3",
    "batched_cholesky_solve_family_f32_48x3_interleaved",
    "batched_inverse_family_f32_48x3",
    "batched_inverse_family_f32_48x3_interleaved",
    "grid_cells_family_f32_96points",
    "grid_neighbor_count_family_f32_96points",
    "spmv_csr_row_warp_family_f32_48rows",
    "spmv_csr_row_thread_family_f32_48rows",
    "spmv_csr_row_warp_family_f16_48rows",
    "spmv_coo_element_thread_family_f32_48x96",
    "spmv_ell_row_thread_family_f32_48x6",
    "spmv_sell_row_thread_slice8_family_f32_48x8",
    "spmm_csr_row_column_thread_family_f32_32x9",
    "philox_fill_family_i32_64",
    "threefry_fill_family_i32_65",
    "squares_fill_family_i32_63",
    "histogram_family_direct_f32_16x96",
    "histogram_family_shared_f32_16x96",
};

fn selectedMetalConformanceCase(comptime Spec: type) bool {
    if (comptime @hasDecl(Spec, "buildArtifact")) {
        inline for (selected_metal_family_conformance_cases) |selected| {
            if (std.mem.eql(u8, Spec.name, selected)) return true;
        }
        return false;
    }
    if (comptime Spec.expectation != .verified) return false;
    return switch (comptime Spec.output.dtype) {
        .f32, .f16, .i32 => true,
        else => false,
    };
}

fn expectConformanceCasePass(result: records.Case) !void {
    if (std.mem.eql(u8, result.status, "pass")) return;
    pretty.diagnostic.writeStderrText(
        "metal conformance case failed: name={s} status={s} detail={s} max_abs_error={d} " ++
            "tolerance={d}\n",
        .{ result.name, result.status, result.detail, result.max_abs_error, result.tolerance },
    );
    return error.MetalConformanceCaseFailed;
}

fn initMetalStateOrSkip(allocator: std.mem.Allocator) !gpu.metal.State {
    try accy.validation.gating.skipIfBuildFlagDisabled(.metal);
    if (!accy.validation.gating.appleMetalPlatform()) {
        return accy.validation.gating.skip(.metal, .unsupported_platform);
    }
    return gpu.metal.State.initDevice(allocator) catch |err| switch (err) {
        error.RuntimeUnavailable => return accy.validation.gating.skip(
            .metal,
            .metal_device_missing,
        ),
        else => return err,
    };
}

pub const FamilyAccess = enum { input, inout };

pub const FamilyBuffer = struct {
    tensor: Tensor,
    access: FamilyAccess = .input,
};

pub fn runFamilyCase(
    comptime Spec: type,
    allocator: std.mem.Allocator,
    handle: BackendHandle,
    gate: Gate,
) !records.Case {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const compile_start = nowNs();
    var artifact = try Spec.buildArtifact(allocator, handle);
    defer artifact.deinit();
    const ptxas_status = acceptSingleArtifact(allocator, artifact, gate.assembler);
    const ptxas_ok = !std.mem.eql(u8, ptxas_status, "fail");

    if (gate.mode == .assemble) {
        return .{
            .name = Spec.name,
            .status = if (ptxas_ok) "assembled" else "fail",
            .detail = if (ptxas_ok) "" else "PtxasRejected",
            .ptxas = ptxas_status,
            .kernels = 1,
            .compile_ns = elapsedNs(compile_start),
            .launch_read_ns = 0,
            .checksum = 0,
            .max_abs_error = 0,
            .tolerance = Spec.tolerance,
        };
    }

    const loaded = try handle.loadArtifact(&artifact);
    const compile_ns = elapsedNs(compile_start);

    var seeded: [Spec.buffers.len][]const u8 = undefined;
    var bindings: [Spec.buffers.len]gpu.BufferBinding = undefined;
    inline for (Spec.buffers, 0..) |family_buffer, index| {
        const bytes = try arena.alignedAlloc(u8, .@"16", family_buffer.tensor.byteCount());
        Spec.fillBuffer(index, bytes);
        seeded[index] = bytes;
        const device_buffer = try handle.allocateBuffer(.{
            .byte_size = bytes.len,
            .alignment = 256,
            .dtype = family_buffer.tensor.dtype,
            .element_count = family_buffer.tensor.elementCount(),
        });
        try handle.writeBuffer(.{ .handle = device_buffer, .bytes = bytes });
        bindings[index] = .{
            .handle = device_buffer,
            .access = switch (family_buffer.access) {
                .input => .read_only,
                .inout => .read_write,
            },
            .ownership = device_buffer.ownership,
            .byte_size = device_buffer.byte_size,
        };
    }

    const launch_start = nowNs();
    const runtime_arguments = try Spec.runtimeArguments();
    try handle.launch(.{
        .artifact = &artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = runtime_arguments[0..],
        .geometry = Spec.geometry,
    });
    try handle.synchronize(.{ .scope = .device });

    const observed_tensor = Spec.buffers[Spec.observed].tensor;
    const observed = try arena.alignedAlloc(u8, .@"16", observed_tensor.byteCount());
    try handle.readBuffer(.{ .handle = bindings[Spec.observed].handle, .bytes = observed });
    const launch_read_ns = elapsedNs(launch_start);

    const expected = try arena.alignedAlloc(u8, .@"16", observed_tensor.byteCount());
    Spec.reference(seeded[0..], expected);

    const max_error = maxAbsError(observed_tensor.dtype, expected, observed);
    const numeric_ok = max_error <= Spec.tolerance;
    return .{
        .name = Spec.name,
        .status = if (numeric_ok and ptxas_ok) "pass" else "fail",
        .detail = if (ptxas_ok) "" else "PtxasRejected",
        .ptxas = ptxas_status,
        .kernels = 1,
        .compile_ns = compile_ns,
        .launch_read_ns = launch_read_ns,
        .checksum = finiteOrMax(checksum(observed_tensor.dtype, observed)),
        .max_abs_error = finiteOrMax(max_error),
        .tolerance = Spec.tolerance,
    };
}

fn acceptSingleArtifact(
    allocator: std.mem.Allocator,
    artifact: gpu.KernelArtifact,
    assembler: ?Assembler,
) []const u8 {
    const active = assembler orelse return "skip";
    ptx.assemble.acceptArtifact(allocator, active.dir, active.target, artifact) catch {
        return "fail";
    };
    return "pass";
}
