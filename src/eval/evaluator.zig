const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");

const ir = choir.ir;
const dialects = choir.dialects;
const GpuDialect = choir.dialects.gpu.GpuDialect;
const Dimension = choir.dialects.gpu.Dimension;
const ShuffleMode = choir.dialects.gpu.ShuffleMode;
const WarpOpKind = choir.dialects.gpu.WarpOpKind;
const Bf16 = gpu_abi.Bf16;

pub const EvalError = error{
    InvalidFunction,
    InputCountMismatch,
    InputSizeMismatch,
    UnsupportedOperation,
    UnsupportedType,
    MissingValue,
    MissingAttribute,
    InvalidAttribute,
    InvalidCondition,
    InvalidIndex,
    InvalidMemref,
    InvalidResultCount,
    MissingTerminator,
    DivisionByZero,
    Overflow,
    WhileIterationLimit,
    OutOfMemory,
};

pub const max_while_iterations: usize = 1 << 22;

pub const Diagnostic = choir.backends.contract.VerificationDiagnostic;

pub fn executeKernelFunction(
    allocator: std.mem.Allocator,
    func_op: *ir.Operation,
    args: []const KernelArgument,
    launch: anytype,
) EvalError!void {
    return executeKernelFunctionWithDiagnostic(allocator, func_op, args, launch, null);
}

pub fn executeKernelFunctionWithDiagnostic(
    allocator: std.mem.Allocator,
    func_op: *ir.Operation,
    args: []const KernelArgument,
    launch: anytype,
    diagnostic: ?*Diagnostic,
) EvalError!void {
    var machine = Machine.init(allocator);
    defer machine.deinit();
    return machine.runWithDiagnostic(func_op, args, launch, diagnostic);
}

pub const Machine = struct {
    allocator: std.mem.Allocator,
    evaluator: Evaluator,
    bound: std.ArrayListUnmanaged(RuntimeValue) = .empty,
    lanes: std.ArrayListUnmanaged(LaneState) = .empty,
    lane_refs: std.ArrayListUnmanaged(*LaneState) = .empty,

    pub fn init(allocator: std.mem.Allocator) Machine {
        return .{
            .allocator = allocator,
            .evaluator = Evaluator.init(allocator),
        };
    }

    pub fn deinit(self: *Machine) void {
        for (self.lanes.items) |*lane| lane.deinit();
        self.lanes.deinit(self.allocator);
        self.lane_refs.deinit(self.allocator);
        self.bound.deinit(self.allocator);
        self.evaluator.deinit();
        self.* = undefined;
    }

    pub fn run(
        self: *Machine,
        func_op: *ir.Operation,
        args: []const KernelArgument,
        launch: anytype,
    ) EvalError!void {
        return self.runWithDiagnostic(func_op, args, launch, null);
    }

    pub fn runWithDiagnostic(
        self: *Machine,
        func_op: *ir.Operation,
        args: []const KernelArgument,
        launch: anytype,
        diagnostic: ?*Diagnostic,
    ) EvalError!void {
        if (diagnostic) |captured| captured.len = 0;
        return self.runChecking(func_op, args, launch, diagnostic) catch |err| {
            captureFunctionDiagnostic(diagnostic, "accy/kernel/run", func_op, err);
            return err;
        };
    }

    fn runChecking(
        self: *Machine,
        func_op: *ir.Operation,
        args: []const KernelArgument,
        launch: anytype,
        diagnostic: ?*Diagnostic,
    ) EvalError!void {
        if (!std.mem.eql(u8, func_op.name.name, dialects.FuncDialect.FuncOp.operation_name)) {
            return error.InvalidFunction;
        }
        const region = func_op.getRegion(0) orelse return error.InvalidFunction;
        const entry = region.getEntryBlock() orelse return error.InvalidFunction;
        if (entry.arguments.items.len != args.len) return error.InputCountMismatch;

        self.evaluator.resetRun();
        self.evaluator.setDiagnostic("accy/kernel/run", diagnostic);

        try self.bound.resize(self.allocator, args.len);
        for (args, 0..) |arg, i| {
            const block_arg = entry.getArgument(i) orelse return error.InvalidFunction;
            self.bound.items[i] = switch (arg) {
                .memref => |bytes| .{
                    .memref = try self.evaluator.addBorrowedMemref(block_arg.type, bytes),
                },
                .scalar => |value| .{
                    .scalar = try castScalar(try scalarKindOfType(block_arg.type), value),
                },
            };
        }

        const lane_count = try launchBlockThreadCount(launch);
        try self.ensureLanes(lane_count);
        const lane_refs = self.lane_refs.items[0..lane_count];

        for (0..@as(usize, @intCast(launch.grid[2]))) |block_z| {
            for (0..@as(usize, @intCast(launch.grid[1]))) |block_y| {
                for (0..@as(usize, @intCast(launch.grid[0]))) |block_x| {
                    self.evaluator.refillSharedSentinel();
                    var lane_index: usize = 0;
                    for (0..@as(usize, @intCast(launch.block[2]))) |thread_z| {
                        for (0..@as(usize, @intCast(launch.block[1]))) |thread_y| {
                            for (0..@as(usize, @intCast(launch.block[0]))) |thread_x| {
                                const lane = lane_refs[lane_index];
                                lane_index += 1;
                                lane.reset(launchIndex(
                                    launch,
                                    block_x,
                                    block_y,
                                    block_z,
                                    thread_x,
                                    thread_y,
                                    thread_z,
                                ));
                                for (self.bound.items, 0..) |value, i| {
                                    const block_arg = entry.getArgument(i) orelse
                                        return error.InvalidFunction;
                                    try lane.setValue(block_arg, value);
                                }
                            }
                        }
                    }
                    std.debug.assert(lane_index == lane_count);
                    try self.evaluator.evalKernelBlock(entry, lane_refs);
                }
            }
        }
    }

    fn ensureLanes(self: *Machine, lane_count: usize) EvalError!void {
        while (self.lanes.items.len < lane_count) {
            try self.lanes.append(self.allocator, LaneState.init(self.allocator, .{}));
        }
        try self.lane_refs.resize(self.allocator, self.lanes.items.len);
        for (self.lanes.items, 0..) |*lane, index| {
            self.lane_refs.items[index] = lane;
        }
        std.debug.assert(self.lane_refs.items.len >= lane_count);
    }
};

fn captureFunctionDiagnostic(
    diagnostic: ?*Diagnostic,
    stage: []const u8,
    func_op: *ir.Operation,
    err: EvalError,
) void {
    const captured = diagnostic orelse return;
    if (captured.hasText()) return;
    if (functionName(func_op)) |name| {
        setFormattedDiagnostic(captured, "{s}: {s} in {s}", .{ stage, @errorName(err), name });
    } else {
        setFormattedDiagnostic(captured, "{s}: {s}", .{ stage, @errorName(err) });
    }
}

fn captureOpDiagnostic(
    diagnostic: ?*Diagnostic,
    stage: []const u8,
    op: *ir.Operation,
    err: EvalError,
) void {
    const captured = diagnostic orelse return;
    if (captured.hasText()) return;
    setFormattedDiagnostic(captured, "{s}: {s} at {s}", .{ stage, @errorName(err), op.name.name });
}

fn setFormattedDiagnostic(diagnostic: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
    const message = std.fmt.bufPrint(&diagnostic.buffer, fmt, args) catch {
        diagnostic.set("accy/kernel/run: diagnostic truncated");
        return;
    };
    diagnostic.len = message.len;
}

fn functionName(func_op: *ir.Operation) ?[]const u8 {
    const func = dialects.FuncDialect.FuncOp{ .op = func_op };
    return func.getName();
}

pub const ScalarKind = enum {
    bool,
    index,
    i8,
    i16,
    i32,
    u8,
    u16,
    u32,
    i64,
    u64,
    f16,
    bf16,
    f32,
    f64,
};

pub const Scalar = union(ScalarKind) {
    bool: bool,
    index: i64,
    i8: i8,
    i16: i16,
    i32: i32,
    u8: u8,
    u16: u16,
    u32: u32,
    i64: i64,
    u64: u64,
    f16: f16,
    bf16: Bf16,
    f32: f32,
    f64: f64,
};

pub const KernelArgument = union(enum) {
    memref: []u8,
    scalar: Scalar,
};

const LaunchIndex = struct {
    global: [3]i64 = .{ 0, 0, 0 },
    thread: [3]i64 = .{ 0, 0, 0 },
    block: [3]i64 = .{ 0, 0, 0 },
    grid_dim: [3]i64 = .{ 1, 1, 1 },
    block_dim: [3]i64 = .{ 1, 1, 1 },
};

const LaneState = struct {
    values: std.AutoHashMap(*ir.Value, RuntimeValue),
    launch: LaunchIndex,

    fn init(allocator: std.mem.Allocator, index: LaunchIndex) LaneState {
        return .{
            .values = std.AutoHashMap(*ir.Value, RuntimeValue).init(allocator),
            .launch = index,
        };
    }

    fn deinit(self: *LaneState) void {
        self.values.deinit();
    }

    fn reset(self: *LaneState, index: LaunchIndex) void {
        self.values.clearRetainingCapacity();
        self.launch = index;
    }

    fn setValue(self: *LaneState, value: *ir.Value, runtime_value: RuntimeValue) EvalError!void {
        try self.values.put(value, runtime_value);
    }
};

const warp_size: usize = 32;

pub const shared_alloc_sentinel: u8 = 0x7F;

fn launchBlockThreadCount(launch: anytype) EvalError!usize {
    const xy = std.math.mul(u32, launch.block[0], launch.block[1]) catch return error.Overflow;
    const xyz = std.math.mul(u32, xy, launch.block[2]) catch return error.Overflow;
    return std.math.cast(usize, xyz) orelse return error.Overflow;
}

fn launchIndex(
    launch: anytype,
    block_x: usize,
    block_y: usize,
    block_z: usize,
    thread_x: usize,
    thread_y: usize,
    thread_z: usize,
) LaunchIndex {
    const block_i: [3]i64 = .{ @intCast(block_x), @intCast(block_y), @intCast(block_z) };
    const thread_i: [3]i64 = .{ @intCast(thread_x), @intCast(thread_y), @intCast(thread_z) };
    const block_dim_i: [3]i64 = .{
        @intCast(launch.block[0]),
        @intCast(launch.block[1]),
        @intCast(launch.block[2]),
    };
    return .{
        .block = block_i,
        .thread = thread_i,
        .block_dim = block_dim_i,
        .grid_dim = .{
            @intCast(launch.grid[0]),
            @intCast(launch.grid[1]),
            @intCast(launch.grid[2]),
        },
        .global = .{
            block_i[0] * block_dim_i[0] + thread_i[0],
            block_i[1] * block_dim_i[1] + thread_i[1],
            block_i[2] * block_dim_i[2] + thread_i[2],
        },
    };
}

fn linearThreadIndex(index: LaunchIndex) EvalError!usize {
    const x = std.math.cast(usize, index.thread[0]) orelse return error.Overflow;
    const y = std.math.cast(usize, index.thread[1]) orelse return error.Overflow;
    const z = std.math.cast(usize, index.thread[2]) orelse return error.Overflow;
    const dim_x = std.math.cast(usize, index.block_dim[0]) orelse return error.Overflow;
    const dim_y = std.math.cast(usize, index.block_dim[1]) orelse return error.Overflow;
    const y_base = std.math.mul(usize, y, dim_x) catch return error.Overflow;
    const plane = std.math.mul(usize, dim_x, dim_y) catch return error.Overflow;
    const z_base = std.math.mul(usize, z, plane) catch return error.Overflow;
    return std.math.add(
        usize,
        std.math.add(usize, x, y_base) catch return error.Overflow,
        z_base,
    ) catch return error.Overflow;
}

fn blockActiveMask(index: LaunchIndex) EvalError!u32 {
    const current_warp = try warpId(index);
    const dim_x = std.math.cast(usize, index.block_dim[0]) orelse return error.Overflow;
    const dim_y = std.math.cast(usize, index.block_dim[1]) orelse return error.Overflow;
    const dim_z = std.math.cast(usize, index.block_dim[2]) orelse return error.Overflow;
    const xy = std.math.mul(usize, dim_x, dim_y) catch return error.Overflow;
    const count = std.math.mul(usize, xy, dim_z) catch return error.Overflow;
    var mask: u32 = 0;
    var local: usize = 0;
    while (local < count) : (local += 1) {
        if (local / warp_size != current_warp) continue;
        mask |= @as(u32, 1) << @intCast(local % warp_size);
    }
    return mask;
}

fn laneId(index: LaunchIndex) EvalError!usize {
    return (try linearThreadIndex(index)) % warp_size;
}

fn warpId(index: LaunchIndex) EvalError!usize {
    return (try linearThreadIndex(index)) / warp_size;
}

fn activeMaskForLanes(index: LaunchIndex, lanes: []*LaneState) EvalError!u32 {
    const current_warp = try warpId(index);
    var mask: u32 = 0;
    for (lanes) |lane| {
        if (try warpId(lane.launch) != current_warp) continue;
        mask |= @as(u32, 1) << @intCast(try laneId(lane.launch));
    }
    return mask;
}

const RuntimeValue = union(enum) {
    scalar: Scalar,
    f32x4: [4]f32,
    memref: usize,
};

const Memref = struct {
    element: ScalarKind,
    bytes: []u8,
    owned: bool = true,
};

const LoopLane = struct {
    lane: *LaneState,
    iv: i64,
    upper: i64,
    step: i64,
};

const ControlScratch = struct {
    frames: std.ArrayListUnmanaged(*Frame) = .empty,
    depth: usize = 0,

    const Frame = struct {
        lanes_a: std.ArrayListUnmanaged(*LaneState) = .empty,
        lanes_b: std.ArrayListUnmanaged(*LaneState) = .empty,
        indices: std.ArrayListUnmanaged(usize) = .empty,
        loops: std.ArrayListUnmanaged(LoopLane) = .empty,
        carried: std.ArrayListUnmanaged(RuntimeValue) = .empty,

        fn reset(self: *Frame) void {
            self.lanes_a.clearRetainingCapacity();
            self.lanes_b.clearRetainingCapacity();
            self.indices.clearRetainingCapacity();
            self.loops.clearRetainingCapacity();
            self.carried.clearRetainingCapacity();
        }

        fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
            self.lanes_a.deinit(allocator);
            self.lanes_b.deinit(allocator);
            self.indices.deinit(allocator);
            self.loops.deinit(allocator);
            self.carried.deinit(allocator);
        }
    };

    fn acquire(self: *ControlScratch, allocator: std.mem.Allocator) EvalError!*Frame {
        std.debug.assert(self.depth <= self.frames.items.len);
        if (self.depth == self.frames.items.len) {
            const frame = try allocator.create(Frame);
            errdefer allocator.destroy(frame);
            frame.* = .{};
            try self.frames.append(allocator, frame);
        }
        const frame = self.frames.items[self.depth];
        self.depth += 1;
        frame.reset();
        return frame;
    }

    fn release(self: *ControlScratch) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
    }

    fn deinit(self: *ControlScratch, allocator: std.mem.Allocator) void {
        for (self.frames.items) |frame| {
            frame.deinit(allocator);
            allocator.destroy(frame);
        }
        self.frames.deinit(allocator);
    }
};

const Evaluator = struct {
    allocator: std.mem.Allocator,
    values: std.AutoHashMap(*ir.Value, RuntimeValue),
    memrefs: std.ArrayList(Memref),
    shared_allocs: std.AutoHashMap(*ir.Operation, usize),
    shared_bytes: std.AutoHashMap(*ir.Operation, []u8),
    scratch: ControlScratch = .{},
    warps: std.AutoHashMap(usize, void),
    launch: LaunchIndex = .{},
    active_lanes: ?[]*LaneState = null,
    diagnostic_stage: []const u8 = "accy/eval",
    diagnostic: ?*Diagnostic = null,

    const BinaryOp = enum { add, sub, mul, div, rem, min, max };

    const UnaryOp = enum {
        neg,
        abs,
        sqrt,
        exp,
        log,
        tanh,
        sin,
        cos,
        tan,
        floor,
        round,
        trunc,
        tf32_round,
    };

    const LogicalOp = enum { and_, or_, xor };

    const ShiftOp = enum { shl, shr, ushr };

    const GpuIdKind = enum { global, thread, block, block_dim, grid_dim };

    const WarpVoteKind = enum { all, any, ballot };

    fn init(allocator: std.mem.Allocator) Evaluator {
        return .{
            .allocator = allocator,
            .values = std.AutoHashMap(*ir.Value, RuntimeValue).init(allocator),
            .memrefs = .empty,
            .shared_allocs = std.AutoHashMap(*ir.Operation, usize).init(allocator),
            .shared_bytes = std.AutoHashMap(*ir.Operation, []u8).init(allocator),
            .warps = std.AutoHashMap(usize, void).init(allocator),
        };
    }

    fn deinit(self: *Evaluator) void {
        self.releaseOwnedMemrefs();
        self.memrefs.deinit(self.allocator);
        self.shared_allocs.deinit();
        var shared_iter = self.shared_bytes.valueIterator();
        while (shared_iter.next()) |bytes| {
            self.allocator.free(bytes.*);
        }
        self.shared_bytes.deinit();
        self.warps.deinit();
        self.scratch.deinit(self.allocator);
        self.values.deinit();
    }

    fn resetRun(self: *Evaluator) void {
        std.debug.assert(self.scratch.depth == 0);
        self.releaseOwnedMemrefs();
        self.memrefs.clearRetainingCapacity();
        self.shared_allocs.clearRetainingCapacity();
        self.values.clearRetainingCapacity();
        self.launch = .{};
        self.active_lanes = null;
    }

    fn releaseOwnedMemrefs(self: *Evaluator) void {
        for (self.memrefs.items) |memref| {
            if (memref.owned) self.allocator.free(memref.bytes);
        }
    }

    fn setDiagnostic(self: *Evaluator, stage: []const u8, diagnostic: ?*Diagnostic) void {
        self.diagnostic_stage = stage;
        self.diagnostic = diagnostic;
    }

    fn failOp(self: *Evaluator, op: *ir.Operation, err: EvalError) EvalError {
        captureOpDiagnostic(self.diagnostic, self.diagnostic_stage, op, err);
        return err;
    }

    fn refillSharedSentinel(self: *Evaluator) void {
        var iter = self.shared_allocs.valueIterator();
        while (iter.next()) |memref_index| {
            std.debug.assert(memref_index.* < self.memrefs.items.len);
            const memref = &self.memrefs.items[memref_index.*];
            @memset(memref.bytes, shared_alloc_sentinel);
        }
    }

    fn addBorrowedMemref(self: *Evaluator, typ: ir.Type, bytes: []u8) EvalError!usize {
        const desc = try describeMemrefType(typ);
        if (desc.byte_size) |byte_size| {
            if (bytes.len < byte_size) return error.InputSizeMismatch;
        }
        return self.appendMemref(.{ .element = desc.element, .bytes = bytes, .owned = false });
    }

    fn appendMemref(self: *Evaluator, memref: Memref) EvalError!usize {
        errdefer if (memref.owned) self.allocator.free(memref.bytes);
        try self.memrefs.append(self.allocator, memref);
        return self.memrefs.items.len - 1;
    }

    fn setValue(self: *Evaluator, value: *ir.Value, runtime_value: RuntimeValue) EvalError!void {
        try self.values.put(value, runtime_value);
    }

    fn resolve(self: *Evaluator, value: *ir.Value) EvalError!RuntimeValue {
        return self.values.get(value) orelse error.MissingValue;
    }

    fn evalBlock(self: *Evaluator, block: *ir.Block) EvalError![]RuntimeValue {
        var iter = block.operations.head;
        while (iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            if (std.mem.eql(u8, op.name.name, dialects.FuncDialect.ReturnOp.operation_name) or
                std.mem.eql(u8, op.name.name, dialects.ScfDialect.YieldOp.operation_name))
            {
                return self.collectOperands(op) catch |err| return self.failOp(op, err);
            }

            try self.evalOpWithDiagnostic(op);
            iter = op.next_op;
        }
        return error.MissingTerminator;
    }

    fn evalKernelBlock(self: *Evaluator, block: *ir.Block, lanes: []*LaneState) EvalError!void {
        var iter = block.operations.head;
        while (iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            if (std.mem.eql(u8, op.name.name, dialects.FuncDialect.ReturnOp.operation_name)) {
                if (op.operands.items.len != 0) return self.failOp(op, error.UnsupportedOperation);
                return;
            }
            if (std.mem.eql(u8, op.name.name, dialects.ScfDialect.YieldOp.operation_name)) {
                return self.failOp(op, error.UnsupportedOperation);
            }

            const handled_collective = self.evalKernelCollective(
                op,
                lanes,
            ) catch |err| return self.failOp(op, err);
            if (!handled_collective) {
                if (std.mem.eql(u8, op.name.name, dialects.ScfDialect.IfOp.operation_name)) {
                    self.evalKernelIf(op, lanes) catch |err| return self.failOp(op, err);
                } else if (std.mem.eql(
                    u8,
                    op.name.name,
                    dialects.ScfDialect.ForOp.operation_name,
                )) {
                    self.evalKernelFor(op, lanes) catch |err| return self.failOp(op, err);
                } else if (std.mem.eql(
                    u8,
                    op.name.name,
                    dialects.ScfDialect.WhileOp.operation_name,
                )) {
                    self.evalKernelWhile(op, lanes) catch |err| return self.failOp(op, err);
                } else {
                    for (lanes) |lane| {
                        self.evalLaneOp(lane, op, lanes) catch |err| return self.failOp(op, err);
                    }
                }
            }
            iter = op.next_op;
        }
        return error.MissingTerminator;
    }

    fn evalKernelYieldBlock(
        self: *Evaluator,
        block: *ir.Block,
        lanes: []*LaneState,
        parent: *ir.Operation,
    ) EvalError!void {
        var iter = block.operations.head;
        while (iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            if (std.mem.eql(u8, op.name.name, dialects.ScfDialect.YieldOp.operation_name)) {
                if (op.operands.items.len != parent.getNumResults()) {
                    return self.failOp(op, error.InvalidResultCount);
                }
                for (lanes) |lane| {
                    for (op.operands.items, 0..) |operand, result_index| {
                        const result = parent.getResult(result_index) orelse
                            return error.InvalidResultCount;
                        lane.setValue(
                            result,
                            try self.resolveLane(lane, operand.value),
                        ) catch |err| return self.failOp(op, err);
                    }
                }
                return;
            }
            if (std.mem.eql(u8, op.name.name, dialects.FuncDialect.ReturnOp.operation_name)) {
                return self.failOp(op, error.UnsupportedOperation);
            }

            const handled_collective = self.evalKernelCollective(
                op,
                lanes,
            ) catch |err| return self.failOp(op, err);
            if (!handled_collective) {
                if (std.mem.eql(u8, op.name.name, dialects.ScfDialect.IfOp.operation_name)) {
                    self.evalKernelIf(op, lanes) catch |err| return self.failOp(op, err);
                } else if (std.mem.eql(
                    u8,
                    op.name.name,
                    dialects.ScfDialect.ForOp.operation_name,
                )) {
                    self.evalKernelFor(op, lanes) catch |err| return self.failOp(op, err);
                } else if (std.mem.eql(
                    u8,
                    op.name.name,
                    dialects.ScfDialect.WhileOp.operation_name,
                )) {
                    self.evalKernelWhile(op, lanes) catch |err| return self.failOp(op, err);
                } else {
                    for (lanes) |lane| {
                        self.evalLaneOp(lane, op, lanes) catch |err| return self.failOp(op, err);
                    }
                }
            }
            iter = op.next_op;
        }
        return error.MissingTerminator;
    }

    fn evalKernelWhile(self: *Evaluator, op: *ir.Operation, lanes: []*LaneState) EvalError!void {
        const while_op = dialects.ScfDialect.WhileOp{ .op = op };
        const carry_count = op.operands.items.len;
        if (op.getNumResults() != carry_count) return error.InvalidResultCount;
        const before = while_op.getBeforeBlock();
        const after = while_op.getAfterBlock();
        if (before.arguments.items.len != carry_count) return error.UnsupportedOperation;
        if (after.arguments.items.len != carry_count) return error.UnsupportedOperation;

        for (lanes) |lane| {
            for (0..carry_count) |i| {
                const carried = try self.resolveLane(lane, op.operands.items[i].value);
                try lane.setValue(before.getArgument(i).?, carried);
            }
        }

        const frame = try self.scratch.acquire(self.allocator);
        defer self.scratch.release();
        const active = &frame.lanes_a;
        const continuing = &frame.lanes_b;
        try active.ensureTotalCapacity(self.allocator, lanes.len);
        try continuing.ensureTotalCapacity(self.allocator, lanes.len);
        active.appendSliceAssumeCapacity(lanes);

        var iterations: usize = 0;
        while (active.items.len != 0) {
            if (iterations >= max_while_iterations) return error.WhileIterationLimit;
            iterations += 1;

            const terminator = try self.evalKernelBlockUntil(
                before,
                active.items,
                dialects.ScfDialect.ConditionOp.operation_name,
            );
            const condition_op = dialects.ScfDialect.ConditionOp{ .op = terminator };
            const cond_value = condition_op.getCondition();
            const args = condition_op.getArgs();
            if (args.len != carry_count) return error.InvalidResultCount;

            continuing.clearRetainingCapacity();
            for (active.items) |lane| {
                if (try self.boolOfLane(lane, cond_value)) {
                    for (args, 0..) |arg, i| {
                        try lane.setValue(after.getArgument(i).?, try self.resolveLane(lane, arg));
                    }
                    try continuing.append(self.allocator, lane);
                } else {
                    for (args, 0..) |arg, i| {
                        const result = op.getResult(i) orelse return error.InvalidResultCount;
                        try lane.setValue(result, try self.resolveLane(lane, arg));
                    }
                }
            }
            active.clearRetainingCapacity();
            try active.appendSlice(self.allocator, continuing.items);
            if (active.items.len == 0) break;

            const yield_op = try self.evalKernelBlockUntil(
                after,
                active.items,
                dialects.ScfDialect.YieldOp.operation_name,
            );
            if (yield_op.operands.items.len != carry_count) return error.InvalidResultCount;
            for (active.items) |lane| {
                for (yield_op.operands.items, 0..) |operand, i| {
                    try lane.setValue(
                        before.getArgument(i).?,
                        try self.resolveLane(lane, operand.value),
                    );
                }
            }
        }
    }

    fn evalKernelBlockUntil(
        self: *Evaluator,
        block: *ir.Block,
        lanes: []*LaneState,
        terminator_name: []const u8,
    ) EvalError!*ir.Operation {
        var iter = block.operations.head;
        while (iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            if (std.mem.eql(u8, op.name.name, terminator_name)) return op;
            if (std.mem.eql(u8, op.name.name, dialects.FuncDialect.ReturnOp.operation_name)) {
                return self.failOp(op, error.UnsupportedOperation);
            }

            const handled_collective = self.evalKernelCollective(
                op,
                lanes,
            ) catch |err| return self.failOp(op, err);
            if (!handled_collective) {
                if (std.mem.eql(u8, op.name.name, dialects.ScfDialect.IfOp.operation_name)) {
                    self.evalKernelIf(op, lanes) catch |err| return self.failOp(op, err);
                } else if (std.mem.eql(
                    u8,
                    op.name.name,
                    dialects.ScfDialect.ForOp.operation_name,
                )) {
                    self.evalKernelFor(op, lanes) catch |err| return self.failOp(op, err);
                } else if (std.mem.eql(
                    u8,
                    op.name.name,
                    dialects.ScfDialect.WhileOp.operation_name,
                )) {
                    self.evalKernelWhile(op, lanes) catch |err| return self.failOp(op, err);
                } else {
                    for (lanes) |lane| {
                        self.evalLaneOp(lane, op, lanes) catch |err| return self.failOp(op, err);
                    }
                }
            }
            iter = op.next_op;
        }
        return error.MissingTerminator;
    }

    fn evalKernelIf(self: *Evaluator, op: *ir.Operation, lanes: []*LaneState) EvalError!void {
        if (op.operands.items.len != 1) return error.UnsupportedOperation;
        const frame = try self.scratch.acquire(self.allocator);
        defer self.scratch.release();
        const then_lanes = &frame.lanes_a;
        const else_lanes = &frame.lanes_b;
        try then_lanes.ensureTotalCapacity(self.allocator, lanes.len);
        try else_lanes.ensureTotalCapacity(self.allocator, lanes.len);

        for (lanes) |lane| {
            if (try self.boolOfLane(lane, op.operands.items[0].value)) {
                then_lanes.appendAssumeCapacity(lane);
            } else {
                else_lanes.appendAssumeCapacity(lane);
            }
        }

        if (then_lanes.items.len != 0) {
            const region = op.getRegion(0) orelse return error.UnsupportedOperation;
            const block = region.getEntryBlock() orelse return error.UnsupportedOperation;
            try self.evalKernelYieldBlock(block, then_lanes.items, op);
        }
        if (else_lanes.items.len != 0) {
            const region = op.getRegion(1) orelse {
                if (op.getNumResults() == 0) return;
                return error.UnsupportedOperation;
            };
            const block = region.getEntryBlock() orelse return error.UnsupportedOperation;
            try self.evalKernelYieldBlock(block, else_lanes.items, op);
        }
    }

    fn evalKernelFor(self: *Evaluator, op: *ir.Operation, lanes: []*LaneState) EvalError!void {
        if (op.operands.items.len < 3) return error.UnsupportedOperation;
        const iter_count = op.operands.items.len - 3;
        if (op.getNumResults() != iter_count) return error.InvalidResultCount;
        const region = op.getRegion(0) orelse return error.UnsupportedOperation;
        const body = region.getEntryBlock() orelse return error.UnsupportedOperation;
        if (body.arguments.items.len != iter_count + 1) return error.UnsupportedOperation;

        const frame = try self.scratch.acquire(self.allocator);
        defer self.scratch.release();
        try frame.loops.resize(self.allocator, lanes.len);
        const loop_lanes = frame.loops.items;

        const iter_value_count = std.math.mul(
            usize,
            lanes.len,
            iter_count,
        ) catch return error.Overflow;
        try frame.carried.resize(self.allocator, iter_value_count);
        const iter_values = frame.carried.items;

        for (lanes, 0..) |lane, lane_index| {
            const lower = try self.indexOfLane(lane, op.operands.items[0].value);
            const upper = try self.indexOfLane(lane, op.operands.items[1].value);
            const step = try self.indexOfLane(lane, op.operands.items[2].value);
            if (step <= 0) return error.UnsupportedOperation;
            loop_lanes[lane_index] = .{
                .lane = lane,
                .iv = lower,
                .upper = upper,
                .step = step,
            };
            for (0..iter_count) |iter_index| {
                iter_values[lane_index * iter_count + iter_index] = try self.resolveLane(
                    lane,
                    op.operands.items[3 + iter_index].value,
                );
            }
        }

        const active_lanes = &frame.lanes_a;
        const active_indices = &frame.indices;
        try active_lanes.ensureTotalCapacity(self.allocator, lanes.len);
        try active_indices.ensureTotalCapacity(self.allocator, lanes.len);

        while (true) {
            active_lanes.clearRetainingCapacity();
            active_indices.clearRetainingCapacity();

            for (loop_lanes, 0..) |loop_lane, lane_index| {
                if (loop_lane.iv >= loop_lane.upper) continue;
                const lane = loop_lane.lane;
                try lane.setValue(
                    body.getArgument(0) orelse return error.UnsupportedOperation,
                    .{ .scalar = .{ .index = loop_lane.iv } },
                );
                for (0..iter_count) |iter_index| {
                    try lane.setValue(
                        body.getArgument(iter_index + 1) orelse return error.UnsupportedOperation,
                        iter_values[lane_index * iter_count + iter_index],
                    );
                }
                active_lanes.appendAssumeCapacity(lane);
                active_indices.appendAssumeCapacity(lane_index);
            }

            if (active_lanes.items.len == 0) break;

            try self.evalKernelYieldBlock(body, active_lanes.items, op);

            for (active_indices.items) |lane_index| {
                const lane = loop_lanes[lane_index].lane;
                for (0..iter_count) |iter_index| {
                    const result = op.getResult(iter_index) orelse return error.InvalidResultCount;
                    iter_values[
                        lane_index * iter_count + iter_index
                    ] = try self.resolveLane(lane, result);
                }
                loop_lanes[lane_index].iv = std.math.add(
                    i64,
                    loop_lanes[lane_index].iv,
                    loop_lanes[lane_index].step,
                ) catch return error.Overflow;
            }
        }

        for (lanes, 0..) |lane, lane_index| {
            for (0..iter_count) |iter_index| {
                const result = op.getResult(iter_index) orelse return error.InvalidResultCount;
                try lane.setValue(result, iter_values[lane_index * iter_count + iter_index]);
            }
        }
    }

    fn evalLaneOp(
        self: *Evaluator,
        lane: *LaneState,
        op: *ir.Operation,
        active_lanes: []*LaneState,
    ) EvalError!void {
        const previous_values = self.values;
        const previous_launch = self.launch;
        const previous_active_lanes = self.active_lanes;
        self.values = lane.values;
        self.launch = lane.launch;
        self.active_lanes = active_lanes;
        defer {
            lane.values = self.values;
            self.values = previous_values;
            self.launch = previous_launch;
            self.active_lanes = previous_active_lanes;
        }
        try self.evalOpWithDiagnostic(op);
    }

    fn collectOperands(self: *Evaluator, op: *ir.Operation) EvalError![]RuntimeValue {
        const values = try self.allocator.alloc(RuntimeValue, op.operands.items.len);
        errdefer self.allocator.free(values);
        for (op.operands.items, 0..) |operand, i| {
            values[i] = try self.resolve(operand.value);
        }
        return values;
    }

    fn evalOp(self: *Evaluator, op: *ir.Operation) EvalError!void {
        const name = op.name.name;
        if (std.mem.eql(u8, name, dialects.ArithDialect.ConstantOp.operation_name)) {
            return self.evalConstant(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.AddOp.operation_name)) {
            return self.evalBinary(op, .add);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.SubOp.operation_name)) {
            return self.evalBinary(op, .sub);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.MulOp.operation_name)) {
            return self.evalBinary(op, .mul);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.UmulhiOp.operation_name)) {
            return self.evalUmulhi(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.DivOp.operation_name)) {
            return self.evalBinary(op, .div);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.RemOp.operation_name)) {
            return self.evalBinary(op, .rem);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.MinOp.operation_name)) {
            return self.evalBinary(op, .min);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.MaxOp.operation_name)) {
            return self.evalBinary(op, .max);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.NegOp.operation_name)) {
            return self.evalUnary(op, .neg);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.AbsOp.operation_name)) {
            return self.evalUnary(op, .abs);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.SqrtOp.operation_name)) {
            return self.evalUnary(op, .sqrt);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.ExpOp.operation_name)) {
            return self.evalUnary(op, .exp);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.LogOp.operation_name)) {
            return self.evalUnary(op, .log);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.TanhOp.operation_name)) {
            return self.evalUnary(op, .tanh);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.SinOp.operation_name)) {
            return self.evalUnary(op, .sin);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.CosOp.operation_name)) {
            return self.evalUnary(op, .cos);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.TanOp.operation_name)) {
            return self.evalUnary(op, .tan);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.FloorOp.operation_name)) {
            return self.evalUnary(op, .floor);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.RoundOp.operation_name)) {
            return self.evalUnary(op, .round);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.TruncOp.operation_name)) {
            return self.evalUnary(op, .trunc);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.Tf32RoundOp.operation_name)) {
            return self.evalUnary(op, .tf32_round);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.PowOp.operation_name)) {
            return self.evalPow(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.Atan2Op.operation_name)) {
            return self.evalAtan2(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.FmaOp.operation_name)) {
            return self.evalFma(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.CmpOp.operation_name)) {
            return self.evalCmp(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.CastOp.operation_name)) {
            return self.evalCast(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.SelectOp.operation_name)) {
            return self.evalSelect(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.AndOp.operation_name)) {
            return self.evalLogical(op, .and_);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.OrOp.operation_name)) {
            return self.evalLogical(op, .or_);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.XorOp.operation_name)) {
            return self.evalLogical(op, .xor);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.NotOp.operation_name)) {
            return self.evalNot(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.PopCountOp.operation_name)) {
            return self.evalPopCount(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.ShlOp.operation_name)) {
            return self.evalShift(op, .shl);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.ShrOp.operation_name)) {
            return self.evalShift(op, .shr);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.UshrOp.operation_name)) {
            return self.evalShift(op, .ushr);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.BitcastOp.operation_name)) {
            return self.evalBitcast(op);
        }
        if (std.mem.eql(u8, name, dialects.MemrefDialect.AllocaOp.operation_name)) {
            return self.evalAlloca(op);
        }
        if (std.mem.eql(u8, name, dialects.MemrefDialect.AllocOp.operation_name)) {
            return self.evalAlloca(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.ExtractOp.operation_name)) {
            return self.evalVecExtract(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.SplatOp.operation_name)) {
            return self.evalVecSplat(op);
        }
        if (std.mem.eql(u8, name, dialects.ArithDialect.InsertOp.operation_name)) {
            return self.evalVecInsert(op);
        }
        if (std.mem.eql(u8, name, dialects.MemrefDialect.LoadOp.operation_name)) {
            return self.evalLoad(op);
        }
        if (std.mem.eql(u8, name, dialects.MemrefDialect.StoreOp.operation_name)) {
            return self.evalStore(op);
        }
        if (std.mem.eql(u8, name, dialects.MemrefDialect.AtomicRmwOp.operation_name)) {
            return self.evalAtomicRmw(op);
        }
        if (std.mem.eql(u8, name, dialects.MemrefDialect.AtomicCasOp.operation_name)) {
            return self.evalAtomicCas(op);
        }
        if (std.mem.eql(u8, name, dialects.ScfDialect.ForOp.operation_name)) {
            return self.evalFor(op);
        }
        if (std.mem.eql(u8, name, dialects.ScfDialect.WhileOp.operation_name)) {
            return self.evalWhile(op);
        }
        if (std.mem.eql(u8, name, dialects.ScfDialect.IfOp.operation_name)) return self.evalIf(op);
        if (std.mem.eql(u8, name, GpuDialect.GlobalIdxOp.operation_name)) {
            return self.evalGpuId(op, .global);
        }
        if (std.mem.eql(u8, name, GpuDialect.ThreadIdxOp.operation_name)) {
            return self.evalGpuId(op, .thread);
        }
        if (std.mem.eql(u8, name, GpuDialect.BlockIdxOp.operation_name)) {
            return self.evalGpuId(op, .block);
        }
        if (std.mem.eql(u8, name, GpuDialect.BlockDimOp.operation_name)) {
            return self.evalGpuId(op, .block_dim);
        }
        if (std.mem.eql(u8, name, GpuDialect.GridDimOp.operation_name)) {
            return self.evalGpuId(op, .grid_dim);
        }
        if (std.mem.eql(u8, name, GpuDialect.LaneIdOp.operation_name)) return self.evalLaneId(op);
        if (std.mem.eql(u8, name, GpuDialect.WarpIdOp.operation_name)) return self.evalWarpId(op);
        if (std.mem.eql(u8, name, GpuDialect.ActiveMaskOp.operation_name)) {
            return self.evalActiveMask(op);
        }
        if (std.mem.eql(u8, name, GpuDialect.SyncWarpOp.operation_name)) return;
        if (std.mem.eql(u8, name, GpuDialect.WarpReduceOp.operation_name)) {
            return error.UnsupportedOperation;
        }
        if (std.mem.eql(u8, name, GpuDialect.BarrierOp.operation_name)) return;
        if (std.mem.eql(u8, name, GpuDialect.FenceOp.operation_name)) return;
        if (std.mem.eql(u8, name, GpuDialect.CpAsyncSharedOp.operation_name)) {
            return self.evalCpAsyncShared(op);
        }
        if (std.mem.eql(u8, name, GpuDialect.CpAsyncCommitOp.operation_name)) return;
        if (std.mem.eql(u8, name, GpuDialect.CpAsyncWaitOp.operation_name)) return;
        return error.UnsupportedOperation;
    }

    fn evalOpWithDiagnostic(self: *Evaluator, op: *ir.Operation) EvalError!void {
        self.evalOp(op) catch |err| return self.failOp(op, err);
    }

    fn evalConstant(self: *Evaluator, op: *ir.Operation) EvalError!void {
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const attr = op.getAttr("value") orelse return error.MissingAttribute;
        try self.setOnlyResult(op, .{ .scalar = try scalarFromAttribute(kind, attr) });
    }

    fn evalBinary(self: *Evaluator, op: *ir.Operation, binary_op: BinaryOp) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const lhs = try self.scalarOf(op.operands.items[0].value);
        const rhs = try self.scalarOf(op.operands.items[1].value);
        try self.setOnlyResult(op, .{ .scalar = try evalScalarBinary(kind, binary_op, lhs, rhs) });
    }

    fn evalUnary(self: *Evaluator, op: *ir.Operation, unary_op: UnaryOp) EvalError!void {
        if (op.operands.items.len != 1) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const input = try self.scalarOf(op.operands.items[0].value);
        try self.setOnlyResult(op, .{ .scalar = try evalScalarUnary(kind, unary_op, input) });
    }

    fn evalPow(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const base = try self.scalarOf(op.operands.items[0].value);
        const exponent = try self.scalarOf(op.operands.items[1].value);
        try self.setOnlyResult(op, .{ .scalar = try evalScalarPow(kind, base, exponent) });
    }

    fn evalAtan2(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const y = try self.scalarOf(op.operands.items[0].value);
        const x = try self.scalarOf(op.operands.items[1].value);
        try self.setOnlyResult(op, .{ .scalar = try evalScalarAtan2(kind, y, x) });
    }

    fn evalFma(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 3) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const a = try self.scalarOf(op.operands.items[0].value);
        const b = try self.scalarOf(op.operands.items[1].value);
        const c = try self.scalarOf(op.operands.items[2].value);
        try self.setOnlyResult(op, .{ .scalar = try evalScalarFma(kind, a, b, c) });
    }

    fn evalCmp(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        const predicate = try cmpPredicate(op);
        const lhs = try self.scalarOf(op.operands.items[0].value);
        const rhs = try self.scalarOf(op.operands.items[1].value);
        try self.setOnlyResult(op, .{
            .scalar = .{ .bool = try evalCmpPredicate(predicate, lhs, rhs) },
        });
    }

    fn evalCast(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 1) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const target = try scalarKindOfType(result.type);
        const input = try self.scalarOf(op.operands.items[0].value);
        try self.setOnlyResult(op, .{ .scalar = try castScalar(target, input) });
    }

    fn evalSelect(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 3) return error.UnsupportedOperation;
        const cond = try self.boolOf(op.operands.items[0].value);
        const chosen = if (cond)
            try self.resolve(op.operands.items[1].value)
        else
            try self.resolve(op.operands.items[2].value);
        try self.setOnlyResult(op, chosen);
    }

    fn evalLogical(self: *Evaluator, op: *ir.Operation, logical_op: LogicalOp) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const lhs = try self.scalarOf(op.operands.items[0].value);
        const rhs = try self.scalarOf(op.operands.items[1].value);
        try self.setOnlyResult(op, .{
            .scalar = try evalScalarLogical(kind, logical_op, lhs, rhs),
        });
    }

    fn evalNot(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 1) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const input = try self.scalarOf(op.operands.items[0].value);
        try self.setOnlyResult(op, .{ .scalar = try evalScalarNot(kind, input) });
    }

    fn evalPopCount(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 1) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const input = try self.scalarOf(op.operands.items[0].value);
        try self.setOnlyResult(op, .{ .scalar = try evalScalarPopCount(kind, input) });
    }

    fn evalShift(self: *Evaluator, op: *ir.Operation, shift_op: ShiftOp) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const value = try self.scalarOf(op.operands.items[0].value);
        const shift = try self.scalarOf(op.operands.items[1].value);
        try self.setOnlyResult(op, .{
            .scalar = try evalScalarShift(kind, shift_op, value, shift),
        });
    }

    fn evalBitcast(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 1) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const target = try scalarKindOfType(result.type);
        const input = try self.scalarOf(op.operands.items[0].value);
        try self.setOnlyResult(op, .{ .scalar = try evalScalarBitcast(target, input) });
    }

    fn evalUmulhi(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const kind = try scalarKindOfType(result.type);
        const lhs = try self.scalarOf(op.operands.items[0].value);
        const rhs = try self.scalarOf(op.operands.items[1].value);
        try self.setOnlyResult(op, .{ .scalar = try evalScalarUmulhi(kind, lhs, rhs) });
    }

    fn evalAlloca(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len > 1) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const desc = try describeMemrefType(result.type);
        const shared_alloc = desc.addr_space == .shared and std.mem.eql(
            u8,
            op.name.name,
            dialects.MemrefDialect.AllocOp.operation_name,
        );
        if (shared_alloc) {
            if (self.shared_allocs.get(op)) |memref_index| {
                try self.setOnlyResult(op, .{ .memref = memref_index });
                return;
            }
        }
        const byte_size = desc.byte_size orelse blk: {
            if (op.operands.items.len != 1) return error.UnsupportedType;
            const elements = try self.indexOf(op.operands.items[0].value);
            if (elements < 0) return error.InvalidIndex;
            const element_count = std.math.cast(u64, elements) orelse return error.Overflow;
            const byte_size_u64 = std.math.mul(
                u64,
                element_count,
                scalarByteSize(desc.element),
            ) catch return error.Overflow;
            break :blk std.math.cast(usize, byte_size_u64) orelse return error.Overflow;
        };
        if (shared_alloc) {
            const bytes = try self.retainedSharedBytes(op, byte_size);
            @memset(bytes, shared_alloc_sentinel);
            const memref_index = try self.appendMemref(
                .{ .element = desc.element, .bytes = bytes, .owned = false },
            );
            try self.shared_allocs.put(op, memref_index);
            try self.setOnlyResult(op, .{ .memref = memref_index });
            return;
        }
        const bytes = try self.allocator.alloc(u8, byte_size);
        errdefer self.allocator.free(bytes);
        @memset(bytes, 0);
        const memref_index = try self.appendMemref(.{ .element = desc.element, .bytes = bytes });
        try self.setOnlyResult(op, .{ .memref = memref_index });
    }

    fn retainedSharedBytes(self: *Evaluator, op: *ir.Operation, byte_size: usize) EvalError![]u8 {
        const entry = try self.shared_bytes.getOrPut(op);
        if (entry.found_existing and entry.value_ptr.len == byte_size) return entry.value_ptr.*;
        const bytes = self.allocator.alloc(u8, byte_size) catch |err| {
            if (!entry.found_existing) self.shared_bytes.removeByPtr(entry.key_ptr);
            return err;
        };
        if (entry.found_existing) self.allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = bytes;
        return bytes;
    }

    fn evalLoad(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        const memref_index = try self.memrefIndexOf(op.operands.items[0].value);
        const index = try self.indexOf(op.operands.items[1].value);
        const memref = try self.memrefAt(memref_index);
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        if (isVec4F32Type(result.type)) {
            if (memref.element != .f32) return error.UnsupportedType;
            var lanes: [4]f32 = undefined;
            for (&lanes, 0..) |*lane, offset| {
                lane.* = switch (try loadScalar(memref.*, index + @as(i64, @intCast(offset)))) {
                    .f32 => |v| v,
                    else => return error.UnsupportedType,
                };
            }
            try self.setOnlyResult(op, .{ .f32x4 = lanes });
            return;
        }
        const scalar = try loadScalar(memref.*, index);
        try self.setOnlyResult(op, .{ .scalar = scalar });
    }

    fn evalStore(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 3) return error.UnsupportedOperation;
        const stored = try self.resolve(op.operands.items[0].value);
        const memref_index = try self.memrefIndexOf(op.operands.items[1].value);
        const index = try self.indexOf(op.operands.items[2].value);
        const memref = try self.memrefAt(memref_index);
        switch (stored) {
            .f32x4 => |lanes| {
                if (memref.element != .f32) return error.UnsupportedType;
                for (lanes, 0..) |lane, offset| {
                    try storeScalar(memref, index + @as(i64, @intCast(offset)), .{ .f32 = lane });
                }
            },
            .scalar => |scalar| try storeScalar(memref, index, scalar),
            .memref => return error.UnsupportedType,
        }
    }

    fn evalCpAsyncShared(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 4) return error.UnsupportedOperation;
        const copy = GpuDialect.CpAsyncSharedOp{ .op = op };
        const bytes = copy.getBytes() orelse return error.MissingAttribute;
        const dst_ref_index = try self.memrefIndexOf(copy.getDst());
        const dst_index = try self.indexOf(copy.getDstIndex());
        const src_ref_index = try self.memrefIndexOf(copy.getSrc());
        const src_index = try self.indexOf(copy.getSrcIndex());
        const src = try self.memrefAt(src_ref_index);
        const element_bytes: u32 = switch (src.element) {
            .f32, .i32, .u32 => 4,
            else => return error.UnsupportedType,
        };
        if (bytes % element_bytes != 0) return error.UnsupportedOperation;
        const count: i64 = @intCast(bytes / element_bytes);
        var offset: i64 = 0;
        while (offset < count) : (offset += 1) {
            const scalar = try loadScalar(src.*, src_index + offset);
            const dst = try self.memrefAt(dst_ref_index);
            if (dst.element != src.element) return error.UnsupportedType;
            try storeScalar(dst, dst_index + offset, scalar);
        }
    }

    fn evalVecExtract(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 1) return error.UnsupportedOperation;
        const extract = dialects.ArithDialect.ExtractOp{ .op = op };
        const lane_index = extract.getIndex() orelse return error.MissingAttribute;
        if (lane_index < 0 or lane_index > 3) return error.InvalidAttribute;
        const lanes = switch (try self.resolve(op.operands.items[0].value)) {
            .f32x4 => |lanes| lanes,
            else => return error.UnsupportedType,
        };
        try self.setOnlyResult(op, .{ .scalar = .{ .f32 = lanes[@intCast(lane_index)] } });
    }

    fn evalVecSplat(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 1) return error.UnsupportedOperation;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        if (!isVec4F32Type(result.type)) return error.UnsupportedType;
        const value = switch (try self.scalarOf(op.operands.items[0].value)) {
            .f32 => |v| v,
            else => return error.UnsupportedType,
        };
        try self.setOnlyResult(op, .{ .f32x4 = .{ value, value, value, value } });
    }

    fn evalVecInsert(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        const insert = dialects.ArithDialect.InsertOp{ .op = op };
        const lane_index = insert.getIndex() orelse return error.MissingAttribute;
        if (lane_index < 0 or lane_index > 3) return error.InvalidAttribute;
        var lanes = switch (try self.resolve(op.operands.items[0].value)) {
            .f32x4 => |resolved| resolved,
            else => return error.UnsupportedType,
        };
        lanes[@intCast(lane_index)] = switch (try self.scalarOf(op.operands.items[1].value)) {
            .f32 => |v| v,
            else => return error.UnsupportedType,
        };
        try self.setOnlyResult(op, .{ .f32x4 = lanes });
    }

    fn evalAtomicRmw(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 3) return error.UnsupportedOperation;
        const kind = (dialects.MemrefDialect.AtomicRmwOp{ .op = op }).getKind() orelse
            return error.MissingAttribute;
        const operand = try self.scalarOf(op.operands.items[0].value);
        const memref_index = try self.memrefIndexOf(op.operands.items[1].value);
        const index = try self.indexOf(op.operands.items[2].value);
        const memref = try self.memrefAt(memref_index);
        const old = try loadScalar(memref.*, index);
        const updated = try atomicApply(kind, old, operand);
        try storeScalar(memref, index, updated);
        try self.setOnlyResult(op, .{ .scalar = old });
    }

    fn evalAtomicCas(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 4) return error.UnsupportedOperation;
        const memref_index = try self.memrefIndexOf(op.operands.items[2].value);
        const index = try self.indexOf(op.operands.items[3].value);
        const memref = try self.memrefAt(memref_index);
        const expected = try castScalar(
            memref.element,
            try self.scalarOf(op.operands.items[0].value),
        );
        const desired = try castScalar(
            memref.element,
            try self.scalarOf(op.operands.items[1].value),
        );
        const old = try loadScalar(memref.*, index);
        if (try evalCmpPredicate(.eq, old, expected)) {
            try storeScalar(memref, index, desired);
        }
        try self.setOnlyResult(op, .{ .scalar = old });
    }

    fn evalGpuId(self: *Evaluator, op: *ir.Operation, kind: GpuIdKind) EvalError!void {
        const dim = gpuDimension(op) orelse return error.MissingAttribute;
        const index = dimensionIndex(dim);
        const value = switch (kind) {
            .global => self.launch.global[index],
            .thread => self.launch.thread[index],
            .block => self.launch.block[index],
            .block_dim => self.launch.block_dim[index],
            .grid_dim => self.launch.grid_dim[index],
        };
        try self.setOnlyResult(op, .{ .scalar = .{ .index = value } });
    }

    fn evalLaneId(self: *Evaluator, op: *ir.Operation) EvalError!void {
        try self.setOnlyResult(op, .{ .scalar = .{ .index = @intCast(try laneId(self.launch)) } });
    }

    fn evalWarpId(self: *Evaluator, op: *ir.Operation) EvalError!void {
        try self.setOnlyResult(op, .{ .scalar = .{ .index = @intCast(try warpId(self.launch)) } });
    }

    fn evalActiveMask(self: *Evaluator, op: *ir.Operation) EvalError!void {
        const mask = if (self.active_lanes) |lanes|
            try activeMaskForLanes(self.launch, lanes)
        else
            try blockActiveMask(self.launch);
        try self.setOnlyResult(op, .{ .scalar = .{ .i32 = @bitCast(mask) } });
    }

    fn evalKernelCollective(
        self: *Evaluator,
        op: *ir.Operation,
        lanes: []*LaneState,
    ) EvalError!bool {
        if (std.mem.eql(u8, op.name.name, GpuDialect.WarpReduceOp.operation_name)) {
            try self.evalWarpReduce(op, lanes);
            return true;
        }
        if (std.mem.eql(u8, op.name.name, GpuDialect.WarpScanOp.operation_name)) {
            try self.evalWarpScan(op, lanes);
            return true;
        }
        if (std.mem.eql(u8, op.name.name, GpuDialect.ShflSyncOp.operation_name)) {
            try self.evalWarpShuffle(op, lanes);
            return true;
        }
        if (std.mem.eql(u8, op.name.name, GpuDialect.AllSyncOp.operation_name)) {
            try self.evalWarpVote(op, lanes, .all);
            return true;
        }
        if (std.mem.eql(u8, op.name.name, GpuDialect.AnySyncOp.operation_name)) {
            try self.evalWarpVote(op, lanes, .any);
            return true;
        }
        if (std.mem.eql(u8, op.name.name, GpuDialect.BallotSyncOp.operation_name)) {
            try self.evalWarpVote(op, lanes, .ballot);
            return true;
        }
        if (std.mem.eql(u8, op.name.name, GpuDialect.MmaSyncOp.operation_name)) {
            try self.evalMmaSync(op, lanes);
            return true;
        }
        return false;
    }

    fn f32OfLane(self: *Evaluator, lane: *LaneState, value: *ir.Value) EvalError!f32 {
        return scalarToF32(try self.scalarOfLane(lane, value));
    }

    fn evalMmaSync(self: *Evaluator, op: *ir.Operation, lanes: []*LaneState) EvalError!void {
        if (op.operands.items.len != 10) return error.UnsupportedOperation;
        if (op.getNumResults() != 4) return error.InvalidResultCount;
        const mma = GpuDialect.MmaSyncOp{ .op = op };
        const shape = mma.getShape() orelse return error.MissingAttribute;
        if (shape.m != 16 or shape.n != 8 or shape.k != 8) return error.UnsupportedOperation;

        self.warps.clearRetainingCapacity();
        for (lanes) |seed| {
            const warp = try warpId(seed.launch);
            if (self.warps.contains(warp)) continue;
            try self.warps.put(warp, {});

            var members: [warp_size]?*LaneState = @splat(null);
            for (lanes) |candidate| {
                if (try warpId(candidate.launch) != warp) continue;
                members[try laneId(candidate.launch)] = candidate;
            }

            var a: [16][8]f32 = undefined;
            var b: [8][8]f32 = undefined;
            var c: [16][8]f32 = undefined;
            for (0..warp_size) |lane_id| {
                const member = members[lane_id] orelse return error.UnsupportedOperation;
                const group = lane_id >> 2;
                const tid = lane_id & 3;
                a[group][tid] = try self.f32OfLane(member, mma.getA(0));
                a[group + 8][tid] = try self.f32OfLane(member, mma.getA(1));
                a[group][tid + 4] = try self.f32OfLane(member, mma.getA(2));
                a[group + 8][tid + 4] = try self.f32OfLane(member, mma.getA(3));
                b[tid][group] = try self.f32OfLane(member, mma.getB(0));
                b[tid + 4][group] = try self.f32OfLane(member, mma.getB(1));
                c[group][tid * 2] = try self.f32OfLane(member, mma.getC(0));
                c[group][tid * 2 + 1] = try self.f32OfLane(member, mma.getC(1));
                c[group + 8][tid * 2] = try self.f32OfLane(member, mma.getC(2));
                c[group + 8][tid * 2 + 1] = try self.f32OfLane(member, mma.getC(3));
            }

            var d: [16][8]f32 = undefined;
            for (0..16) |row| {
                for (0..8) |col| {
                    var acc = c[row][col];
                    for (0..8) |k| {
                        acc = @mulAdd(f32, a[row][k], b[k][col], acc);
                    }
                    d[row][col] = acc;
                }
            }

            for (0..warp_size) |lane_id| {
                const member = members[lane_id].?;
                const group = lane_id >> 2;
                const tid = lane_id & 3;
                try member.setValue(op.getResult(0).?, .{
                    .scalar = .{ .f32 = d[group][tid * 2] },
                });
                try member.setValue(op.getResult(1).?, .{
                    .scalar = .{ .f32 = d[group][tid * 2 + 1] },
                });
                try member.setValue(op.getResult(2).?, .{
                    .scalar = .{ .f32 = d[group + 8][tid * 2] },
                });
                try member.setValue(op.getResult(3).?, .{
                    .scalar = .{ .f32 = d[group + 8][tid * 2 + 1] },
                });
            }
        }
    }

    fn evalWarpReduce(self: *Evaluator, op: *ir.Operation, lanes: []*LaneState) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        if (op.getNumResults() != 1) return error.InvalidResultCount;
        const reduce = GpuDialect.WarpReduceOp{ .op = op };
        const op_kind = reduce.getOpKind() orelse return error.MissingAttribute;
        const result = reduce.getResult();
        const kind = try scalarKindOfType(result.type);
        const mask_value = reduce.getMask();
        const input_value = reduce.getValue();

        for (lanes) |lane| {
            const target_warp = try warpId(lane.launch);
            const mask = try scalarToMask(try self.scalarOfLane(lane, mask_value));
            var reduced: ?Scalar = null;
            for (lanes) |source_lane| {
                if (try warpId(source_lane.launch) != target_warp) continue;
                const source_lane_id = try laneId(source_lane.launch);
                if ((mask & (@as(u32, 1) << @intCast(source_lane_id))) == 0) continue;
                const source = try self.scalarOfLane(source_lane, input_value);
                reduced = if (reduced) |current|
                    try evalWarpScalar(kind, op_kind, current, source)
                else
                    try castScalar(kind, source);
            }
            try lane.setValue(result, .{
                .scalar = reduced orelse return error.UnsupportedOperation,
            });
        }
    }

    fn evalWarpScan(self: *Evaluator, op: *ir.Operation, lanes: []*LaneState) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        if (op.getNumResults() != 1) return error.InvalidResultCount;
        const scan = GpuDialect.WarpScanOp{ .op = op };
        const op_kind = scan.getOpKind() orelse return error.MissingAttribute;
        const inclusive = scan.isInclusive();
        const result = scan.getResult();
        const kind = try scalarKindOfType(result.type);
        const mask_value = scan.getMask();
        const input_value = scan.getValue();

        for (lanes) |lane| {
            const target_warp = try warpId(lane.launch);
            const target_lane_id = try laneId(lane.launch);
            const mask = try scalarToMask(try self.scalarOfLane(lane, mask_value));
            var scanned: ?Scalar = null;
            var source_lane_id: usize = 0;
            while (source_lane_id < warp_size) : (source_lane_id += 1) {
                if (source_lane_id > target_lane_id) break;
                if (!inclusive and source_lane_id == target_lane_id) break;
                const source_mask = @as(u32, 1) << @intCast(source_lane_id);
                if ((mask & source_mask) == 0) continue;
                for (lanes) |source_lane| {
                    if (try warpId(source_lane.launch) != target_warp) continue;
                    if (try laneId(source_lane.launch) != source_lane_id) continue;
                    const source = try self.scalarOfLane(source_lane, input_value);
                    scanned = if (scanned) |current|
                        try evalWarpScalar(kind, op_kind, current, source)
                    else
                        try castScalar(kind, source);
                    break;
                }
            }
            try lane.setValue(result, .{
                .scalar = scanned orelse try warpIdentity(kind, op_kind),
            });
        }
    }

    fn evalWarpShuffle(self: *Evaluator, op: *ir.Operation, lanes: []*LaneState) EvalError!void {
        if (op.operands.items.len != 3) return error.UnsupportedOperation;
        if (op.getNumResults() != 1) return error.InvalidResultCount;
        const shuffle = GpuDialect.ShflSyncOp{ .op = op };
        const mode = shuffle.getMode() orelse return error.MissingAttribute;
        const result = shuffle.getResult();
        const kind = try scalarKindOfType(result.type);
        const mask_value = shuffle.getMask();
        const input_value = shuffle.getSrc();
        const lane_or_delta_value = shuffle.getLaneOrDelta();

        for (lanes) |lane| {
            const target_warp = try warpId(lane.launch);
            const target_lane_id = try laneId(lane.launch);
            const lane_or_delta = try self.indexOfLane(lane, lane_or_delta_value);
            const source_lane_id = try shuffleSourceLane(mode, target_lane_id, lane_or_delta);
            const source_mask = @as(u32, 1) << @intCast(source_lane_id);
            const mask = try scalarToMask(try self.scalarOfLane(lane, mask_value));
            if ((mask & source_mask) == 0) return error.UnsupportedOperation;

            var found_source = false;
            for (lanes) |source_lane| {
                if (try warpId(source_lane.launch) != target_warp) continue;
                if (try laneId(source_lane.launch) != source_lane_id) continue;
                const source = try self.scalarOfLane(source_lane, input_value);
                try lane.setValue(result, .{ .scalar = try castScalar(kind, source) });
                found_source = true;
                break;
            }
            if (!found_source) return error.UnsupportedOperation;
        }
    }

    fn evalWarpVote(
        self: *Evaluator,
        op: *ir.Operation,
        lanes: []*LaneState,
        vote: WarpVoteKind,
    ) EvalError!void {
        if (op.operands.items.len != 2) return error.UnsupportedOperation;
        if (op.getNumResults() != 1) return error.InvalidResultCount;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        const mask_value = op.operands.items[0].value;
        const predicate_value = op.operands.items[1].value;

        for (lanes) |lane| {
            const target_warp = try warpId(lane.launch);
            const mask = try scalarToMask(try self.scalarOfLane(lane, mask_value));
            var saw_lane = false;
            var all_value = true;
            var any_value = false;
            var ballot_value: u32 = 0;
            for (lanes) |source_lane| {
                if (try warpId(source_lane.launch) != target_warp) continue;
                const source_lane_id = try laneId(source_lane.launch);
                const source_mask = @as(u32, 1) << @intCast(source_lane_id);
                if ((mask & source_mask) == 0) continue;
                saw_lane = true;
                const predicate = try self.boolOfLane(source_lane, predicate_value);
                if (predicate) {
                    any_value = true;
                    ballot_value |= source_mask;
                } else {
                    all_value = false;
                }
            }

            const scalar: Scalar = switch (vote) {
                .all => .{ .bool = saw_lane and all_value },
                .any => .{ .bool = any_value },
                .ballot => .{ .i32 = @bitCast(ballot_value) },
            };
            try lane.setValue(result, .{ .scalar = scalar });
        }
    }

    fn scalarOfLane(self: *Evaluator, lane: *LaneState, value: *ir.Value) EvalError!Scalar {
        _ = self;
        return switch (lane.values.get(value) orelse return error.MissingValue) {
            .scalar => |scalar| scalar,
            .f32x4, .memref => error.UnsupportedType,
        };
    }

    fn resolveLane(self: *Evaluator, lane: *LaneState, value: *ir.Value) EvalError!RuntimeValue {
        _ = self;
        return lane.values.get(value) orelse error.MissingValue;
    }

    fn boolOfLane(self: *Evaluator, lane: *LaneState, value: *ir.Value) EvalError!bool {
        return switch (try self.scalarOfLane(lane, value)) {
            .bool => |v| v,
            else => error.InvalidCondition,
        };
    }

    fn indexOfLane(self: *Evaluator, lane: *LaneState, value: *ir.Value) EvalError!i64 {
        return scalarToI64(try self.scalarOfLane(lane, value));
    }

    fn evalFor(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len < 3) return error.UnsupportedOperation;
        const lower = try self.indexOf(op.operands.items[0].value);
        const upper = try self.indexOf(op.operands.items[1].value);
        const step = try self.indexOf(op.operands.items[2].value);
        if (step <= 0) return error.UnsupportedOperation;

        const iter_count = op.operands.items.len - 3;
        if (op.getNumResults() != iter_count) return error.InvalidResultCount;
        const region = op.getRegion(0) orelse return error.UnsupportedOperation;
        const body = region.getEntryBlock() orelse return error.UnsupportedOperation;
        if (body.arguments.items.len != iter_count + 1) return error.UnsupportedOperation;

        const iter_values = try self.allocator.alloc(RuntimeValue, iter_count);
        defer self.allocator.free(iter_values);
        for (iter_values, 0..) |*value, i| {
            value.* = try self.resolve(op.operands.items[3 + i].value);
        }

        var iv = lower;
        while (iv < upper) {
            try self.setValue(body.getArgument(0).?, .{ .scalar = .{ .index = iv } });
            for (iter_values, 0..) |value, i| {
                try self.setValue(body.getArgument(i + 1).?, value);
            }

            const yielded = try self.evalBlock(body);
            if (yielded.len != iter_count) {
                self.allocator.free(yielded);
                return error.InvalidResultCount;
            }
            @memcpy(iter_values, yielded);
            self.allocator.free(yielded);

            iv = std.math.add(i64, iv, step) catch return error.Overflow;
        }

        for (iter_values, 0..) |value, i| {
            const result = op.getResult(i) orelse return error.InvalidResultCount;
            try self.setValue(result, value);
        }
    }

    fn evalWhile(self: *Evaluator, op: *ir.Operation) EvalError!void {
        const while_op = dialects.ScfDialect.WhileOp{ .op = op };
        const carry_count = op.operands.items.len;
        if (op.getNumResults() != carry_count) return error.InvalidResultCount;
        const before = while_op.getBeforeBlock();
        const after = while_op.getAfterBlock();
        if (before.arguments.items.len != carry_count) return error.UnsupportedOperation;
        if (after.arguments.items.len != carry_count) return error.UnsupportedOperation;

        const carries = try self.allocator.alloc(RuntimeValue, carry_count);
        defer self.allocator.free(carries);
        for (carries, 0..) |*value, i| {
            value.* = try self.resolve(op.operands.items[i].value);
        }

        var iterations: usize = 0;
        while (true) {
            if (iterations >= max_while_iterations) return error.WhileIterationLimit;
            iterations += 1;

            for (carries, 0..) |value, i| {
                try self.setValue(before.getArgument(i).?, value);
            }
            const terminator = try self.evalBlockUntil(
                before,
                dialects.ScfDialect.ConditionOp.operation_name,
            );
            const condition_op = dialects.ScfDialect.ConditionOp{ .op = terminator };
            const args = condition_op.getArgs();
            if (args.len != carry_count) return error.InvalidResultCount;

            if (!(try self.boolOf(condition_op.getCondition()))) {
                for (args, 0..) |arg, i| {
                    const result = op.getResult(i) orelse return error.InvalidResultCount;
                    try self.setValue(result, try self.resolve(arg));
                }
                return;
            }

            for (args, 0..) |arg, i| {
                try self.setValue(after.getArgument(i).?, try self.resolve(arg));
            }
            const yielded = try self.evalBlock(after);
            if (yielded.len != carry_count) {
                self.allocator.free(yielded);
                return error.InvalidResultCount;
            }
            @memcpy(carries, yielded);
            self.allocator.free(yielded);
        }
    }

    fn evalBlockUntil(
        self: *Evaluator,
        block: *ir.Block,
        terminator_name: []const u8,
    ) EvalError!*ir.Operation {
        var iter = block.operations.head;
        while (iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            if (std.mem.eql(u8, op.name.name, terminator_name)) return op;
            try self.evalOpWithDiagnostic(op);
            iter = op.next_op;
        }
        return error.MissingTerminator;
    }

    fn evalIf(self: *Evaluator, op: *ir.Operation) EvalError!void {
        if (op.operands.items.len != 1) return error.UnsupportedOperation;
        const cond = try self.boolOf(op.operands.items[0].value);
        const region = op.getRegion(if (cond) 0 else 1) orelse return error.UnsupportedOperation;
        const block = region.getEntryBlock() orelse return error.UnsupportedOperation;
        const yielded = try self.evalBlock(block);
        defer self.allocator.free(yielded);
        if (yielded.len != op.getNumResults()) return error.InvalidResultCount;
        for (yielded, 0..) |value, i| {
            const result = op.getResult(i) orelse return error.InvalidResultCount;
            try self.setValue(result, value);
        }
    }

    fn setOnlyResult(
        self: *Evaluator,
        op: *ir.Operation,
        runtime_value: RuntimeValue,
    ) EvalError!void {
        if (op.getNumResults() != 1) return error.InvalidResultCount;
        const result = op.getResult(0) orelse return error.InvalidResultCount;
        try self.setValue(result, runtime_value);
    }

    fn scalarOf(self: *Evaluator, value: *ir.Value) EvalError!Scalar {
        return switch (try self.resolve(value)) {
            .scalar => |scalar| scalar,
            .f32x4, .memref => error.UnsupportedType,
        };
    }

    fn boolOf(self: *Evaluator, value: *ir.Value) EvalError!bool {
        return switch (try self.scalarOf(value)) {
            .bool => |v| v,
            else => error.InvalidCondition,
        };
    }

    fn indexOf(self: *Evaluator, value: *ir.Value) EvalError!i64 {
        return scalarToI64(try self.scalarOf(value));
    }

    fn memrefIndexOf(self: *Evaluator, value: *ir.Value) EvalError!usize {
        return switch (try self.resolve(value)) {
            .memref => |idx| idx,
            .scalar, .f32x4 => error.InvalidMemref,
        };
    }

    fn memrefAt(self: *Evaluator, index: usize) EvalError!*Memref {
        if (index >= self.memrefs.items.len) return error.InvalidMemref;
        return &self.memrefs.items[index];
    }
};

const MemrefDesc = struct {
    element: ScalarKind,
    byte_size: ?usize,
    addr_space: dialects.AddressSpace,
};

fn describeMemrefType(typ: ir.Type) EvalError!MemrefDesc {
    const storage = typ.getDialectStorage() orelse return error.UnsupportedType;
    if (!std.mem.eql(u8, storage.name, dialects.MemrefDialect.name)) return error.UnsupportedType;
    const params = dialects.MemrefDialect.parseMemrefParams(storage.param_key) orelse
        return error.UnsupportedType;
    const element = scalarKindFromTypeName(params.element_type_name) orelse
        return error.UnsupportedType;
    const byte_size = if (params.size) |elements| blk: {
        const byte_size_u64 = std.math.mul(u64, elements, scalarByteSize(
            element,
        )) catch return error.Overflow;
        break :blk std.math.cast(usize, byte_size_u64) orelse return error.Overflow;
    } else null;
    return .{ .element = element, .byte_size = byte_size, .addr_space = params.addr_space };
}

fn scalarKindOfType(typ: ir.Type) EvalError!ScalarKind {
    const storage = typ.getDialectStorage() orelse return error.UnsupportedType;
    return scalarKindFromTypeName(storage.name) orelse error.UnsupportedType;
}

fn scalarKindFromTypeName(name: []const u8) ?ScalarKind {
    const kind = dialects.arith.scalarKindFromTypeName(name) orelse return null;
    return switch (kind) {
        .bool => .bool,
        .index => .index,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .i64 => .i64,
        .u64 => .u64,
        .f16 => .f16,
        .bf16 => .bf16,
        .f32 => .f32,
        .f64 => .f64,
    };
}

fn gpuDimension(op: *ir.Operation) ?Dimension {
    const attr = op.getAttr("dim") orelse return null;
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
    return Dimension.fromString(dialect_attr.payload);
}

fn dimensionIndex(dim: Dimension) usize {
    return switch (dim) {
        .x => 0,
        .y => 1,
        .z => 2,
    };
}

fn scalarByteSize(kind: ScalarKind) u64 {
    return switch (kind) {
        .bool => 1,
        .i8, .u8 => 1,
        .i16, .u16, .f16, .bf16 => 2,
        .index, .i64, .u64, .f64 => 8,
        .i32, .u32, .f32 => 4,
    };
}

fn scalarFromAttribute(kind: ScalarKind, attr: ir.Attribute) EvalError!Scalar {
    return switch (kind) {
        .bool => .{
            .bool = dialects.ArithDialect.getBoolValue(attr) orelse return error.InvalidAttribute,
        },
        .index => .{
            .index = dialects.ArithDialect.getIntValue(attr) orelse return error.InvalidAttribute,
        },
        .i8 => .{ .i8 = std.math.cast(
            i8,
            dialects.ArithDialect.getIntValue(attr) orelse return error.InvalidAttribute,
        ) orelse return error.Overflow },
        .i16 => .{ .i16 = std.math.cast(
            i16,
            dialects.ArithDialect.getIntValue(attr) orelse return error.InvalidAttribute,
        ) orelse return error.Overflow },
        .i32 => .{ .i32 = std.math.cast(
            i32,
            dialects.ArithDialect.getIntValue(attr) orelse return error.InvalidAttribute,
        ) orelse return error.Overflow },
        .u8 => .{ .u8 = std.math.cast(
            u8,
            dialects.ArithDialect.getIntValue(attr) orelse return error.InvalidAttribute,
        ) orelse return error.Overflow },
        .u16 => .{ .u16 = std.math.cast(
            u16,
            dialects.ArithDialect.getIntValue(attr) orelse return error.InvalidAttribute,
        ) orelse return error.Overflow },
        .u32 => .{ .u32 = std.math.cast(
            u32,
            dialects.ArithDialect.getIntValue(attr) orelse return error.InvalidAttribute,
        ) orelse return error.Overflow },
        .i64 => .{
            .i64 = dialects.ArithDialect.getIntValue(attr) orelse return error.InvalidAttribute,
        },
        .u64 => .{ .u64 = std.math.cast(
            u64,
            dialects.ArithDialect.getIntValue(attr) orelse return error.InvalidAttribute,
        ) orelse return error.Overflow },
        .f16 => .{ .f16 = @floatCast(
            dialects.ArithDialect.getFloatValue(attr) orelse return error.InvalidAttribute,
        ) },
        .bf16 => .{ .bf16 = Bf16.fromF32(@floatCast(
            dialects.ArithDialect.getFloatValue(attr) orelse return error.InvalidAttribute,
        )) },
        .f32 => .{ .f32 = @floatCast(
            dialects.ArithDialect.getFloatValue(attr) orelse return error.InvalidAttribute,
        ) },
        .f64 => .{
            .f64 = dialects.ArithDialect.getFloatValue(attr) orelse return error.InvalidAttribute,
        },
    };
}

fn isVec4F32Type(typ: ir.Type) bool {
    const name = typ.getDialectTypeName() orelse return false;
    return std.mem.eql(u8, name, dialects.arith.type_names.vec4xf32);
}

fn loadScalar(memref: Memref, index_i64: i64) EvalError!Scalar {
    const index = try checkedElementIndex(memref, index_i64);
    const offset = index * @as(usize, @intCast(scalarByteSize(memref.element)));
    return switch (memref.element) {
        .bool => .{ .bool = memref.bytes[offset] != 0 },
        .i8 => .{ .i8 = @bitCast(memref.bytes[offset]) },
        .u8 => .{ .u8 = memref.bytes[offset] },
        .i16 => .{ .i16 = std.mem.readInt(i16, memref.bytes[offset..][0..2], .little) },
        .u16 => .{ .u16 = std.mem.readInt(u16, memref.bytes[offset..][0..2], .little) },
        .i32 => .{ .i32 = std.mem.readInt(i32, memref.bytes[offset..][0..4], .little) },
        .u32 => .{ .u32 = std.mem.readInt(u32, memref.bytes[offset..][0..4], .little) },
        .i64 => .{ .i64 = std.mem.readInt(i64, memref.bytes[offset..][0..8], .little) },
        .u64 => .{ .u64 = std.mem.readInt(u64, memref.bytes[offset..][0..8], .little) },
        .index => .{ .index = std.mem.readInt(i64, memref.bytes[offset..][0..8], .little) },
        .f16 => .{ .f16 = @bitCast(std.mem.readInt(u16, memref.bytes[offset..][0..2], .little)) },
        .bf16 => .{
            .bf16 = .{ .bits = std.mem.readInt(u16, memref.bytes[offset..][0..2], .little) },
        },
        .f32 => .{ .f32 = @bitCast(std.mem.readInt(u32, memref.bytes[offset..][0..4], .little)) },
        .f64 => .{ .f64 = @bitCast(std.mem.readInt(u64, memref.bytes[offset..][0..8], .little)) },
    };
}

fn storeScalar(memref: *Memref, index_i64: i64, scalar: Scalar) EvalError!void {
    const index = try checkedElementIndex(memref.*, index_i64);
    const offset = index * @as(usize, @intCast(scalarByteSize(memref.element)));
    const value = try castScalar(memref.element, scalar);
    switch (value) {
        .bool => |v| memref.bytes[offset] = if (v) 1 else 0,
        .i8 => |v| memref.bytes[offset] = @bitCast(v),
        .u8 => |v| memref.bytes[offset] = v,
        .i16 => |v| std.mem.writeInt(i16, memref.bytes[offset..][0..2], v, .little),
        .u16 => |v| std.mem.writeInt(u16, memref.bytes[offset..][0..2], v, .little),
        .i32 => |v| std.mem.writeInt(i32, memref.bytes[offset..][0..4], v, .little),
        .u32 => |v| std.mem.writeInt(u32, memref.bytes[offset..][0..4], v, .little),
        .i64 => |v| std.mem.writeInt(i64, memref.bytes[offset..][0..8], v, .little),
        .u64 => |v| std.mem.writeInt(u64, memref.bytes[offset..][0..8], v, .little),
        .index => |v| std.mem.writeInt(i64, memref.bytes[offset..][0..8], v, .little),
        .f16 => |v| std.mem.writeInt(u16, memref.bytes[offset..][0..2], @bitCast(v), .little),
        .bf16 => |v| std.mem.writeInt(u16, memref.bytes[offset..][0..2], v.bits, .little),
        .f32 => |v| std.mem.writeInt(u32, memref.bytes[offset..][0..4], @bitCast(v), .little),
        .f64 => |v| std.mem.writeInt(u64, memref.bytes[offset..][0..8], @bitCast(v), .little),
    }
}

fn atomicApply(kind: dialects.AtomicRmwKind, old: Scalar, operand: Scalar) EvalError!Scalar {
    if (std.meta.activeTag(old) != std.meta.activeTag(operand)) return error.UnsupportedType;
    return switch (kind) {
        .add => switch (old) {
            .i8 => |v| .{ .i8 = v +% operand.i8 },
            .i16 => |v| .{ .i16 = v +% operand.i16 },
            .i32 => |v| .{ .i32 = v +% operand.i32 },
            .u8 => |v| .{ .u8 = v +% operand.u8 },
            .u16 => |v| .{ .u16 = v +% operand.u16 },
            .u32 => |v| .{ .u32 = v +% operand.u32 },
            .i64 => |v| .{ .i64 = v +% operand.i64 },
            .u64 => |v| .{ .u64 = v +% operand.u64 },
            .f32 => |v| .{ .f32 = v + operand.f32 },
            .f64 => |v| .{ .f64 = v + operand.f64 },
            .bool, .index, .f16, .bf16 => error.UnsupportedType,
        },
        .min => switch (old) {
            .i8 => |v| .{ .i8 = @min(v, operand.i8) },
            .i16 => |v| .{ .i16 = @min(v, operand.i16) },
            .i32 => |v| .{ .i32 = @min(v, operand.i32) },
            .u8 => |v| .{ .u8 = @min(v, operand.u8) },
            .u16 => |v| .{ .u16 = @min(v, operand.u16) },
            .u32 => |v| .{ .u32 = @min(v, operand.u32) },
            .i64 => |v| .{ .i64 = @min(v, operand.i64) },
            .u64 => |v| .{ .u64 = @min(v, operand.u64) },
            else => error.UnsupportedType,
        },
        .max => switch (old) {
            .i8 => |v| .{ .i8 = @max(v, operand.i8) },
            .i16 => |v| .{ .i16 = @max(v, operand.i16) },
            .i32 => |v| .{ .i32 = @max(v, operand.i32) },
            .u8 => |v| .{ .u8 = @max(v, operand.u8) },
            .u16 => |v| .{ .u16 = @max(v, operand.u16) },
            .u32 => |v| .{ .u32 = @max(v, operand.u32) },
            .i64 => |v| .{ .i64 = @max(v, operand.i64) },
            .u64 => |v| .{ .u64 = @max(v, operand.u64) },
            else => error.UnsupportedType,
        },
        .bit_and => switch (old) {
            .i8 => |v| .{ .i8 = v & operand.i8 },
            .i16 => |v| .{ .i16 = v & operand.i16 },
            .i32 => |v| .{ .i32 = v & operand.i32 },
            .u8 => |v| .{ .u8 = v & operand.u8 },
            .u16 => |v| .{ .u16 = v & operand.u16 },
            .u32 => |v| .{ .u32 = v & operand.u32 },
            .i64 => |v| .{ .i64 = v & operand.i64 },
            .u64 => |v| .{ .u64 = v & operand.u64 },
            else => error.UnsupportedType,
        },
        .bit_or => switch (old) {
            .i8 => |v| .{ .i8 = v | operand.i8 },
            .i16 => |v| .{ .i16 = v | operand.i16 },
            .i32 => |v| .{ .i32 = v | operand.i32 },
            .u8 => |v| .{ .u8 = v | operand.u8 },
            .u16 => |v| .{ .u16 = v | operand.u16 },
            .u32 => |v| .{ .u32 = v | operand.u32 },
            .i64 => |v| .{ .i64 = v | operand.i64 },
            .u64 => |v| .{ .u64 = v | operand.u64 },
            else => error.UnsupportedType,
        },
        .bit_xor => switch (old) {
            .i8 => |v| .{ .i8 = v ^ operand.i8 },
            .i16 => |v| .{ .i16 = v ^ operand.i16 },
            .i32 => |v| .{ .i32 = v ^ operand.i32 },
            .u8 => |v| .{ .u8 = v ^ operand.u8 },
            .u16 => |v| .{ .u16 = v ^ operand.u16 },
            .u32 => |v| .{ .u32 = v ^ operand.u32 },
            .i64 => |v| .{ .i64 = v ^ operand.i64 },
            .u64 => |v| .{ .u64 = v ^ operand.u64 },
            else => error.UnsupportedType,
        },
        .exchange => switch (old) {
            .bool => error.UnsupportedType,
            else => operand,
        },
    };
}

fn checkedElementIndex(memref: Memref, index_i64: i64) EvalError!usize {
    if (index_i64 < 0) return error.InvalidIndex;
    const index = std.math.cast(usize, index_i64) orelse return error.InvalidIndex;
    const element_size = @as(usize, @intCast(scalarByteSize(memref.element)));
    if (element_size == 0 or memref.bytes.len % element_size != 0) return error.InvalidMemref;
    if (index >= memref.bytes.len / element_size) return error.InvalidIndex;
    return index;
}

fn evalScalarBinary(
    kind: ScalarKind,
    op: Evaluator.BinaryOp,
    lhs: Scalar,
    rhs: Scalar,
) EvalError!Scalar {
    return switch (kind) {
        .bool => error.UnsupportedType,
        .index => .{ .index = try evalIndexBinary(op, try scalarToI64(lhs), try scalarToI64(rhs)) },
        .i8 => .{ .i8 = try evalIntBinary(i8, op, try scalarToI8(lhs), try scalarToI8(rhs)) },
        .i16 => .{ .i16 = try evalIntBinary(i16, op, try scalarToI16(lhs), try scalarToI16(rhs)) },
        .i32 => .{ .i32 = try evalIntBinary(i32, op, try scalarToI32(lhs), try scalarToI32(rhs)) },
        .u8 => .{ .u8 = try evalIntBinary(u8, op, try scalarToU8(lhs), try scalarToU8(rhs)) },
        .u16 => .{ .u16 = try evalIntBinary(u16, op, try scalarToU16(lhs), try scalarToU16(rhs)) },
        .u32 => .{ .u32 = try evalIntBinary(u32, op, try scalarToU32(lhs), try scalarToU32(rhs)) },
        .i64 => .{ .i64 = try evalIntBinary(i64, op, try scalarToI64(lhs), try scalarToI64(rhs)) },
        .u64 => .{ .u64 = try evalIntBinary(u64, op, try scalarToU64(lhs), try scalarToU64(rhs)) },
        .f16 => .{ .f16 = @floatCast(
            try evalFloatBinary(f32, op, try scalarToF32(lhs), try scalarToF32(rhs)),
        ) },
        .bf16 => .{ .bf16 = Bf16.fromF32(
            try evalFloatBinary(f32, op, try scalarToF32(lhs), try scalarToF32(rhs)),
        ) },
        .f32 => .{
            .f32 = try evalFloatBinary(f32, op, try scalarToF32(lhs), try scalarToF32(rhs)),
        },
        .f64 => .{
            .f64 = try evalFloatBinary(f64, op, try scalarToF64(lhs), try scalarToF64(rhs)),
        },
    };
}

fn evalIntBinary(comptime T: type, op: Evaluator.BinaryOp, lhs: T, rhs: T) EvalError!T {
    return switch (op) {
        .add => lhs +% rhs,
        .sub => lhs -% rhs,
        .mul => lhs *% rhs,
        .div => if (rhs == 0) error.DivisionByZero else @divTrunc(lhs, rhs),
        .rem => if (rhs == 0) error.DivisionByZero else @rem(lhs, rhs),
        .min => @min(lhs, rhs),
        .max => @max(lhs, rhs),
    };
}

fn evalIndexBinary(op: Evaluator.BinaryOp, lhs: i64, rhs: i64) EvalError!i64 {
    return switch (op) {
        .add => std.math.add(i64, lhs, rhs) catch error.Overflow,
        .sub => std.math.sub(i64, lhs, rhs) catch error.Overflow,
        .mul => std.math.mul(i64, lhs, rhs) catch error.Overflow,
        .div => if (rhs == 0) error.DivisionByZero else @divTrunc(lhs, rhs),
        .rem => if (rhs == 0) error.DivisionByZero else @rem(lhs, rhs),
        .min => @min(lhs, rhs),
        .max => @max(lhs, rhs),
    };
}

fn evalFloatBinary(comptime T: type, op: Evaluator.BinaryOp, lhs: T, rhs: T) EvalError!T {
    return switch (op) {
        .add => lhs + rhs,
        .sub => lhs - rhs,
        .mul => lhs * rhs,
        .div => lhs / rhs,
        .rem => error.UnsupportedOperation,
        .min => @min(lhs, rhs),
        .max => @max(lhs, rhs),
    };
}

fn evalScalarUnary(kind: ScalarKind, op: Evaluator.UnaryOp, input: Scalar) EvalError!Scalar {
    return switch (kind) {
        .bool => error.UnsupportedType,
        .index => .{ .index = switch (op) {
            .neg => try checkedNegSigned(i64, try scalarToI64(input)),
            else => return error.UnsupportedType,
        } },
        .i8 => .{ .i8 = switch (op) {
            .neg => try checkedNegSigned(i8, try scalarToI8(input)),
            .abs => try checkedAbsSigned(i8, try scalarToI8(input)),
            else => return error.UnsupportedType,
        } },
        .i16 => .{ .i16 = switch (op) {
            .neg => try checkedNegSigned(i16, try scalarToI16(input)),
            .abs => try checkedAbsSigned(i16, try scalarToI16(input)),
            else => return error.UnsupportedType,
        } },
        .i32 => .{ .i32 = switch (op) {
            .neg => try checkedNegSigned(i32, try scalarToI32(input)),
            .abs => try checkedAbsSigned(i32, try scalarToI32(input)),
            else => return error.UnsupportedType,
        } },
        .u8 => .{ .u8 = switch (op) {
            .neg => 0 -% try scalarToU8(input),
            .abs => try scalarToU8(input),
            else => return error.UnsupportedType,
        } },
        .u16 => .{ .u16 = switch (op) {
            .neg => 0 -% try scalarToU16(input),
            .abs => try scalarToU16(input),
            else => return error.UnsupportedType,
        } },
        .u32 => .{ .u32 = switch (op) {
            .neg => 0 -% try scalarToU32(input),
            .abs => try scalarToU32(input),
            else => return error.UnsupportedType,
        } },
        .i64 => .{ .i64 = switch (op) {
            .neg => try checkedNegSigned(i64, try scalarToI64(input)),
            .abs => try checkedAbsSigned(i64, try scalarToI64(input)),
            else => return error.UnsupportedType,
        } },
        .u64 => .{ .u64 = switch (op) {
            .neg => 0 -% try scalarToU64(input),
            .abs => try scalarToU64(input),
            else => return error.UnsupportedType,
        } },
        .f16 => .{ .f16 = @floatCast(try evalFloatUnary(f32, op, try scalarToF32(input))) },
        .bf16 => .{ .bf16 = Bf16.fromF32(try evalFloatUnary(f32, op, try scalarToF32(input))) },
        .f32 => .{ .f32 = try evalFloatUnary(f32, op, try scalarToF32(input)) },
        .f64 => .{ .f64 = try evalFloatUnary(f64, op, try scalarToF64(input)) },
    };
}

fn checkedNegSigned(comptime T: type, value: T) EvalError!T {
    if (value == std.math.minInt(T)) return error.Overflow;
    return -value;
}

fn checkedAbsSigned(comptime T: type, value: T) EvalError!T {
    if (value == std.math.minInt(T)) return error.Overflow;
    return if (value < 0) -value else value;
}

fn evalFloatUnary(comptime T: type, op: Evaluator.UnaryOp, input: T) EvalError!T {
    return switch (op) {
        .neg => -input,
        .abs => @abs(input),
        .sqrt => @sqrt(input),
        .exp => @exp(input),
        .log => @log(input),
        .tanh => std.math.tanh(input),
        .sin => @sin(input),
        .cos => @cos(input),
        .tan => std.math.tan(input),
        .floor => @floor(input),
        .round => @round(input),
        .trunc => @trunc(input),
        .tf32_round => if (T == f32) tf32RoundF32(input) else error.UnsupportedType,
    };
}

pub fn tf32RoundF32(value: f32) f32 {
    const bits: u32 = @bitCast(value);
    if (bits & 0x7F80_0000 == 0x7F80_0000) return value;
    const rounded = (bits +% 0x1000) & 0xFFFF_E000;
    return @bitCast(rounded);
}

test "tf32RoundF32 truncates mantissa to tf32 grid and preserves specials" {
    try std.testing.expectEqual(@as(f32, 1.0), tf32RoundF32(1.0));
    try std.testing.expectEqual(@as(f32, 0.0), tf32RoundF32(0.0));
    try std.testing.expectEqual(@as(f32, -2.5), tf32RoundF32(-2.5));

    const rounded = tf32RoundF32(1.00006103515625 + 0.00001);
    const rounded_bits: u32 = @bitCast(rounded);
    try std.testing.expectEqual(@as(u32, 0), rounded_bits & 0x1FFF);

    const inf = std.math.inf(f32);
    try std.testing.expectEqual(inf, tf32RoundF32(inf));
    try std.testing.expect(std.math.isNan(tf32RoundF32(std.math.nan(f32))));

    const third = tf32RoundF32(1.0 / 3.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), third, 0.0002);
    const third_bits: u32 = @bitCast(third);
    try std.testing.expectEqual(@as(u32, 0), third_bits & 0x1FFF);
}

fn evalScalarPow(kind: ScalarKind, base: Scalar, exponent: Scalar) EvalError!Scalar {
    return switch (kind) {
        .f16 => .{
            .f16 = @floatCast(std.math.pow(f32, try scalarToF32(base), try scalarToF32(exponent))),
        },
        .bf16 => .{ .bf16 = Bf16.fromF32(
            std.math.pow(f32, try scalarToF32(base), try scalarToF32(exponent)),
        ) },
        .f32 => .{ .f32 = std.math.pow(f32, try scalarToF32(base), try scalarToF32(exponent)) },
        .f64 => .{ .f64 = std.math.pow(f64, try scalarToF64(base), try scalarToF64(exponent)) },
        else => error.UnsupportedType,
    };
}

fn evalScalarAtan2(kind: ScalarKind, y: Scalar, x: Scalar) EvalError!Scalar {
    return switch (kind) {
        .f16 => .{ .f16 = @floatCast(std.math.atan2(try scalarToF32(y), try scalarToF32(x))) },
        .bf16 => .{ .bf16 = Bf16.fromF32(std.math.atan2(try scalarToF32(y), try scalarToF32(x))) },
        .f32 => .{ .f32 = std.math.atan2(try scalarToF32(y), try scalarToF32(x)) },
        .f64 => .{ .f64 = std.math.atan2(try scalarToF64(y), try scalarToF64(x)) },
        else => error.UnsupportedType,
    };
}

fn evalScalarFma(kind: ScalarKind, a: Scalar, b: Scalar, c: Scalar) EvalError!Scalar {
    return switch (kind) {
        .f16 => .{ .f16 = @floatCast(
            @mulAdd(f32, try scalarToF32(a), try scalarToF32(b), try scalarToF32(c)),
        ) },
        .bf16 => .{ .bf16 = Bf16.fromF32(
            @mulAdd(f32, try scalarToF32(a), try scalarToF32(b), try scalarToF32(c)),
        ) },
        .f32 => .{
            .f32 = @mulAdd(f32, try scalarToF32(a), try scalarToF32(b), try scalarToF32(c)),
        },
        .f64 => .{
            .f64 = @mulAdd(f64, try scalarToF64(a), try scalarToF64(b), try scalarToF64(c)),
        },
        else => error.UnsupportedType,
    };
}

const Predicate = enum { eq, ne, lt, le, gt, ge, slt, sle, sgt, sge, ult, ule, ugt, uge };

fn cmpPredicate(op: *ir.Operation) EvalError!Predicate {
    const attr = op.getAttr("predicate") orelse return error.MissingAttribute;
    if (!std.mem.eql(u8, attr.abstract.name, "arith.predicate")) return error.InvalidAttribute;
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return error.InvalidAttribute;
    inline for (
        @typeInfo(Predicate).@"enum".field_names,
        @typeInfo(Predicate).@"enum".field_values,
    ) |field_name, field_name_value| {
        const field = .{ .name = field_name, .value = field_name_value };
        if (std.mem.eql(u8, dialect_attr.payload, field.name)) {
            return @fromBackingInt(@intCast(field.value));
        }
    }
    return error.InvalidAttribute;
}

fn evalCmpPredicate(predicate: Predicate, lhs: Scalar, rhs: Scalar) EvalError!bool {
    return switch (lhs) {
        .f16, .bf16, .f32, .f64 => evalFloatCmp(
            predicate,
            try scalarToF64(lhs),
            try scalarToF64(rhs),
        ),
        .u8 => evalUnsignedCmp(u8, predicate, lhs.u8, try scalarToU8(rhs)),
        .u16 => evalUnsignedCmp(u16, predicate, lhs.u16, try scalarToU16(rhs)),
        .u32 => evalUnsignedCmp(u32, predicate, lhs.u32, try scalarToU32(rhs)),
        .u64 => evalUnsignedCmp(u64, predicate, lhs.u64, try scalarToU64(rhs)),
        else => evalIntCmp(predicate, try scalarToI64(lhs), try scalarToI64(rhs)),
    };
}

fn evalIntCmp(predicate: Predicate, lhs: i64, rhs: i64) bool {
    return switch (predicate) {
        .eq => lhs == rhs,
        .ne => lhs != rhs,
        .lt, .slt => lhs < rhs,
        .le, .sle => lhs <= rhs,
        .gt, .sgt => lhs > rhs,
        .ge, .sge => lhs >= rhs,
        .ult => @as(u64, @bitCast(lhs)) < @as(u64, @bitCast(rhs)),
        .ule => @as(u64, @bitCast(lhs)) <= @as(u64, @bitCast(rhs)),
        .ugt => @as(u64, @bitCast(lhs)) > @as(u64, @bitCast(rhs)),
        .uge => @as(u64, @bitCast(lhs)) >= @as(u64, @bitCast(rhs)),
    };
}

fn evalUnsignedCmp(comptime T: type, predicate: Predicate, lhs: T, rhs: T) bool {
    return switch (predicate) {
        .eq => lhs == rhs,
        .ne => lhs != rhs,
        .lt, .slt, .ult => lhs < rhs,
        .le, .sle, .ule => lhs <= rhs,
        .gt, .sgt, .ugt => lhs > rhs,
        .ge, .sge, .uge => lhs >= rhs,
    };
}

fn evalFloatCmp(predicate: Predicate, lhs: f64, rhs: f64) EvalError!bool {
    return switch (predicate) {
        .eq => lhs == rhs,
        .ne => lhs != rhs,
        .lt, .slt, .ult => lhs < rhs,
        .le, .sle, .ule => lhs <= rhs,
        .gt, .sgt, .ugt => lhs > rhs,
        .ge, .sge, .uge => lhs >= rhs,
    };
}

fn evalScalarLogical(
    kind: ScalarKind,
    op: Evaluator.LogicalOp,
    lhs: Scalar,
    rhs: Scalar,
) EvalError!Scalar {
    return switch (kind) {
        .bool => .{ .bool = switch (op) {
            .and_ => (try scalarToBool(lhs)) and (try scalarToBool(rhs)),
            .or_ => (try scalarToBool(lhs)) or (try scalarToBool(rhs)),
            .xor => (try scalarToBool(lhs)) != (try scalarToBool(rhs)),
        } },
        .index => .{ .index = switch (op) {
            .and_ => (try scalarToI64(lhs)) & (try scalarToI64(rhs)),
            .or_ => (try scalarToI64(lhs)) | (try scalarToI64(rhs)),
            .xor => (try scalarToI64(lhs)) ^ (try scalarToI64(rhs)),
        } },
        .i8 => .{ .i8 = switch (op) {
            .and_ => (try scalarToI8(lhs)) & (try scalarToI8(rhs)),
            .or_ => (try scalarToI8(lhs)) | (try scalarToI8(rhs)),
            .xor => (try scalarToI8(lhs)) ^ (try scalarToI8(rhs)),
        } },
        .i16 => .{ .i16 = switch (op) {
            .and_ => (try scalarToI16(lhs)) & (try scalarToI16(rhs)),
            .or_ => (try scalarToI16(lhs)) | (try scalarToI16(rhs)),
            .xor => (try scalarToI16(lhs)) ^ (try scalarToI16(rhs)),
        } },
        .i32 => .{ .i32 = switch (op) {
            .and_ => (try scalarToI32(lhs)) & (try scalarToI32(rhs)),
            .or_ => (try scalarToI32(lhs)) | (try scalarToI32(rhs)),
            .xor => (try scalarToI32(lhs)) ^ (try scalarToI32(rhs)),
        } },
        .u8 => .{ .u8 = switch (op) {
            .and_ => (try scalarToU8(lhs)) & (try scalarToU8(rhs)),
            .or_ => (try scalarToU8(lhs)) | (try scalarToU8(rhs)),
            .xor => (try scalarToU8(lhs)) ^ (try scalarToU8(rhs)),
        } },
        .u16 => .{ .u16 = switch (op) {
            .and_ => (try scalarToU16(lhs)) & (try scalarToU16(rhs)),
            .or_ => (try scalarToU16(lhs)) | (try scalarToU16(rhs)),
            .xor => (try scalarToU16(lhs)) ^ (try scalarToU16(rhs)),
        } },
        .u32 => .{ .u32 = switch (op) {
            .and_ => (try scalarToU32(lhs)) & (try scalarToU32(rhs)),
            .or_ => (try scalarToU32(lhs)) | (try scalarToU32(rhs)),
            .xor => (try scalarToU32(lhs)) ^ (try scalarToU32(rhs)),
        } },
        .i64 => .{ .i64 = switch (op) {
            .and_ => (try scalarToI64(lhs)) & (try scalarToI64(rhs)),
            .or_ => (try scalarToI64(lhs)) | (try scalarToI64(rhs)),
            .xor => (try scalarToI64(lhs)) ^ (try scalarToI64(rhs)),
        } },
        .u64 => .{ .u64 = switch (op) {
            .and_ => (try scalarToU64(lhs)) & (try scalarToU64(rhs)),
            .or_ => (try scalarToU64(lhs)) | (try scalarToU64(rhs)),
            .xor => (try scalarToU64(lhs)) ^ (try scalarToU64(rhs)),
        } },
        .f16, .bf16, .f32, .f64 => error.UnsupportedType,
    };
}

fn evalWarpScalar(
    kind: ScalarKind,
    op_kind: WarpOpKind,
    lhs: Scalar,
    rhs: Scalar,
) EvalError!Scalar {
    return switch (op_kind) {
        .add => evalScalarBinary(kind, .add, lhs, rhs),
        .max => evalScalarBinary(kind, .max, lhs, rhs),
        .min => evalScalarBinary(kind, .min, lhs, rhs),
        .and_ => evalScalarLogical(kind, .and_, lhs, rhs),
        .or_ => evalScalarLogical(kind, .or_, lhs, rhs),
        .xor => evalScalarLogical(kind, .xor, lhs, rhs),
    };
}

fn warpIdentity(kind: ScalarKind, op_kind: WarpOpKind) EvalError!Scalar {
    return switch (op_kind) {
        .add, .or_, .xor => switch (kind) {
            .bool => if (op_kind == .add) error.UnsupportedType else .{ .bool = false },
            .index => .{ .index = 0 },
            .i8 => .{ .i8 = 0 },
            .i16 => .{ .i16 = 0 },
            .i32 => .{ .i32 = 0 },
            .u8 => .{ .u8 = 0 },
            .u16 => .{ .u16 = 0 },
            .u32 => .{ .u32 = 0 },
            .i64 => .{ .i64 = 0 },
            .u64 => .{ .u64 = 0 },
            .f16 => if (op_kind == .add) .{ .f16 = 0 } else error.UnsupportedType,
            .bf16 => if (op_kind == .add) .{ .bf16 = Bf16.fromF32(0) } else error.UnsupportedType,
            .f32 => if (op_kind == .add) .{ .f32 = 0 } else error.UnsupportedType,
            .f64 => if (op_kind == .add) .{ .f64 = 0 } else error.UnsupportedType,
        },
        .and_ => switch (kind) {
            .bool => .{ .bool = true },
            .index => .{ .index = -1 },
            .i8 => .{ .i8 = -1 },
            .i16 => .{ .i16 = -1 },
            .i32 => .{ .i32 = -1 },
            .u8 => .{ .u8 = std.math.maxInt(u8) },
            .u16 => .{ .u16 = std.math.maxInt(u16) },
            .u32 => .{ .u32 = std.math.maxInt(u32) },
            .i64 => .{ .i64 = -1 },
            .u64 => .{ .u64 = std.math.maxInt(u64) },
            .f16, .bf16, .f32, .f64 => error.UnsupportedType,
        },
        .min => switch (kind) {
            .bool => error.UnsupportedType,
            .index => .{ .index = std.math.maxInt(i64) },
            .i8 => .{ .i8 = std.math.maxInt(i8) },
            .i16 => .{ .i16 = std.math.maxInt(i16) },
            .i32 => .{ .i32 = std.math.maxInt(i32) },
            .u8 => .{ .u8 = std.math.maxInt(u8) },
            .u16 => .{ .u16 = std.math.maxInt(u16) },
            .u32 => .{ .u32 = std.math.maxInt(u32) },
            .i64 => .{ .i64 = std.math.maxInt(i64) },
            .u64 => .{ .u64 = std.math.maxInt(u64) },
            .f16 => .{ .f16 = std.math.inf(f16) },
            .bf16 => .{ .bf16 = Bf16.fromF32(std.math.inf(f32)) },
            .f32 => .{ .f32 = std.math.inf(f32) },
            .f64 => .{ .f64 = std.math.inf(f64) },
        },
        .max => switch (kind) {
            .bool => error.UnsupportedType,
            .index => .{ .index = std.math.minInt(i64) },
            .i8 => .{ .i8 = std.math.minInt(i8) },
            .i16 => .{ .i16 = std.math.minInt(i16) },
            .i32 => .{ .i32 = std.math.minInt(i32) },
            .u8 => .{ .u8 = 0 },
            .u16 => .{ .u16 = 0 },
            .u32 => .{ .u32 = 0 },
            .i64 => .{ .i64 = std.math.minInt(i64) },
            .u64 => .{ .u64 = 0 },
            .f16 => .{ .f16 = -std.math.inf(f16) },
            .bf16 => .{ .bf16 = Bf16.fromF32(-std.math.inf(f32)) },
            .f32 => .{ .f32 = -std.math.inf(f32) },
            .f64 => .{ .f64 = -std.math.inf(f64) },
        },
    };
}

fn shuffleSourceLane(mode: ShuffleMode, target_lane_id: usize, lane_or_delta: i64) EvalError!usize {
    if (lane_or_delta < 0) return error.InvalidIndex;
    const selector = std.math.cast(usize, lane_or_delta) orelse return error.InvalidIndex;
    const source = switch (mode) {
        .sync => selector,
        .down => std.math.add(usize, target_lane_id, selector) catch return error.Overflow,
        .up => if (target_lane_id >= selector)
            target_lane_id - selector
        else
            return error.InvalidIndex,
        .xor => target_lane_id ^ selector,
    };
    if (source >= warp_size) return error.InvalidIndex;
    return source;
}

fn evalScalarNot(kind: ScalarKind, input: Scalar) EvalError!Scalar {
    return switch (kind) {
        .bool => .{ .bool = !(try scalarToBool(input)) },
        .index => .{ .index = ~(try scalarToI64(input)) },
        .i8 => .{ .i8 = ~(try scalarToI8(input)) },
        .i16 => .{ .i16 = ~(try scalarToI16(input)) },
        .i32 => .{ .i32 = ~(try scalarToI32(input)) },
        .u8 => .{ .u8 = ~(try scalarToU8(input)) },
        .u16 => .{ .u16 = ~(try scalarToU16(input)) },
        .u32 => .{ .u32 = ~(try scalarToU32(input)) },
        .i64 => .{ .i64 = ~(try scalarToI64(input)) },
        .u64 => .{ .u64 = ~(try scalarToU64(input)) },
        .f16, .bf16, .f32, .f64 => error.UnsupportedType,
    };
}

fn evalScalarPopCount(kind: ScalarKind, input: Scalar) EvalError!Scalar {
    return switch (kind) {
        .i8 => .{ .i8 = @intCast(@popCount(@as(u8, @bitCast(try scalarToI8(input))))) },
        .u8 => .{ .u8 = @intCast(@popCount(try scalarToU8(input))) },
        .i16 => .{ .i16 = @intCast(@popCount(@as(u16, @bitCast(try scalarToI16(input))))) },
        .u16 => .{ .u16 = @intCast(@popCount(try scalarToU16(input))) },
        .i32 => .{ .i32 = @popCount(@as(u32, @bitCast(try scalarToI32(input)))) },
        .u32 => .{ .u32 = @popCount(try scalarToU32(input)) },
        .i64 => .{ .i64 = @popCount(@as(u64, @bitCast(try scalarToI64(input)))) },
        .u64 => .{ .u64 = @popCount(try scalarToU64(input)) },
        .index => .{ .index = @popCount(@as(u64, @bitCast(try scalarToI64(input)))) },
        .bool, .f16, .bf16, .f32, .f64 => error.UnsupportedType,
    };
}

fn evalScalarUmulhi(kind: ScalarKind, lhs: Scalar, rhs: Scalar) EvalError!Scalar {
    return switch (kind) {
        .i8 => .{ .i8 = umulhiInt(i8, try scalarToI8(lhs), try scalarToI8(rhs)) },
        .u8 => .{ .u8 = umulhiInt(u8, try scalarToU8(lhs), try scalarToU8(rhs)) },
        .i16 => .{ .i16 = umulhiInt(i16, try scalarToI16(lhs), try scalarToI16(rhs)) },
        .u16 => .{ .u16 = umulhiInt(u16, try scalarToU16(lhs), try scalarToU16(rhs)) },
        .i32 => .{ .i32 = umulhiInt(i32, try scalarToI32(lhs), try scalarToI32(rhs)) },
        .u32 => .{ .u32 = umulhiInt(u32, try scalarToU32(lhs), try scalarToU32(rhs)) },
        .i64 => .{ .i64 = umulhiInt(i64, try scalarToI64(lhs), try scalarToI64(rhs)) },
        .u64 => .{ .u64 = umulhiInt(u64, try scalarToU64(lhs), try scalarToU64(rhs)) },
        .bool, .index, .f16, .bf16, .f32, .f64 => error.UnsupportedType,
    };
}

fn umulhiInt(comptime T: type, lhs: T, rhs: T) T {
    const bit_count = @bitSizeOf(T);
    const U = @Int(.unsigned, bit_count);
    const W = @Int(.unsigned, bit_count * 2);
    const product = @as(W, @as(U, @bitCast(lhs))) * @as(W, @as(U, @bitCast(rhs)));
    return @bitCast(@as(U, @truncate(product >> bit_count)));
}

fn evalScalarShift(
    kind: ScalarKind,
    op: Evaluator.ShiftOp,
    value: Scalar,
    shift: Scalar,
) EvalError!Scalar {
    return switch (kind) {
        .i8 => .{ .i8 = try evalSignedShift(i8, op, try scalarToI8(value), try scalarToI8(shift)) },
        .u8 => .{
            .u8 = try evalUnsignedShift(u8, op, try scalarToU8(value), try scalarToU8(shift)),
        },
        .i16 => .{
            .i16 = try evalSignedShift(i16, op, try scalarToI16(value), try scalarToI16(shift)),
        },
        .u16 => .{
            .u16 = try evalUnsignedShift(u16, op, try scalarToU16(value), try scalarToU16(shift)),
        },
        .i32 => .{
            .i32 = try evalSignedShift(i32, op, try scalarToI32(value), try scalarToI32(shift)),
        },
        .u32 => .{
            .u32 = try evalUnsignedShift(u32, op, try scalarToU32(value), try scalarToU32(shift)),
        },
        .i64 => .{
            .i64 = try evalSignedShift(i64, op, try scalarToI64(value), try scalarToI64(shift)),
        },
        .u64 => .{
            .u64 = try evalUnsignedShift(u64, op, try scalarToU64(value), try scalarToU64(shift)),
        },
        .bool, .index, .f16, .bf16, .f32, .f64 => error.UnsupportedType,
    };
}

fn evalSignedShift(comptime T: type, op: Evaluator.ShiftOp, value: T, shift: T) EvalError!T {
    if (shift < 0) return error.UnsupportedOperation;
    const bit_count = @bitSizeOf(T);
    if (@as(u64, @intCast(shift)) >= bit_count) return error.UnsupportedOperation;
    const shift_count: std.math.Log2Int(T) = @intCast(shift);
    const U = @Int(.unsigned, bit_count);
    return switch (op) {
        .shl => @bitCast(@as(U, @bitCast(value)) << shift_count),
        .shr => value >> shift_count,
        .ushr => @bitCast(@as(U, @bitCast(value)) >> shift_count),
    };
}

fn evalUnsignedShift(comptime T: type, op: Evaluator.ShiftOp, value: T, shift: T) EvalError!T {
    const bit_count = @bitSizeOf(T);
    if (@as(u64, @intCast(shift)) >= bit_count) return error.UnsupportedOperation;
    const shift_count: std.math.Log2Int(T) = @intCast(shift);
    return switch (op) {
        .shl => value << shift_count,
        .shr, .ushr => value >> shift_count,
    };
}

fn evalScalarBitcast(target: ScalarKind, input: Scalar) EvalError!Scalar {
    return switch (target) {
        .i8 => switch (input) {
            .i8 => input,
            .u8 => |v| .{ .i8 = @bitCast(v) },
            else => error.UnsupportedType,
        },
        .u8 => switch (input) {
            .u8 => input,
            .i8 => |v| .{ .u8 = @bitCast(v) },
            else => error.UnsupportedType,
        },
        .i16 => switch (input) {
            .i16 => input,
            .u16 => |v| .{ .i16 = @bitCast(v) },
            else => error.UnsupportedType,
        },
        .u16 => switch (input) {
            .u16 => input,
            .i16 => |v| .{ .u16 = @bitCast(v) },
            else => error.UnsupportedType,
        },
        .i32 => switch (input) {
            .i32 => input,
            .u32 => |v| .{ .i32 = @bitCast(v) },
            .f32 => |v| .{ .i32 = @bitCast(v) },
            else => error.UnsupportedType,
        },
        .u32 => switch (input) {
            .u32 => input,
            .i32 => |v| .{ .u32 = @bitCast(v) },
            .f32 => |v| .{ .u32 = @bitCast(v) },
            else => error.UnsupportedType,
        },
        .i64 => switch (input) {
            .i64 => input,
            .u64 => |v| .{ .i64 = @bitCast(v) },
            .f64 => |v| .{ .i64 = @bitCast(v) },
            else => error.UnsupportedType,
        },
        .u64 => switch (input) {
            .u64 => input,
            .i64 => |v| .{ .u64 = @bitCast(v) },
            .f64 => |v| .{ .u64 = @bitCast(v) },
            else => error.UnsupportedType,
        },
        .f32 => switch (input) {
            .f32 => input,
            .i32 => |v| .{ .f32 = @bitCast(v) },
            .u32 => |v| .{ .f32 = @bitCast(v) },
            else => error.UnsupportedType,
        },
        .f64 => switch (input) {
            .f64 => input,
            .i64 => |v| .{ .f64 = @bitCast(v) },
            .u64 => |v| .{ .f64 = @bitCast(v) },
            else => error.UnsupportedType,
        },
        .f16 => switch (input) {
            .f16 => input,
            else => error.UnsupportedType,
        },
        .bf16 => switch (input) {
            .bf16 => input,
            else => error.UnsupportedType,
        },
        .bool, .index => error.UnsupportedType,
    };
}

fn castScalar(kind: ScalarKind, input: Scalar) EvalError!Scalar {
    return switch (kind) {
        .bool => .{ .bool = try scalarToBool(input) },
        .index => .{ .index = try scalarToI64(input) },
        .i8 => .{ .i8 = try scalarToI8(input) },
        .i16 => .{ .i16 = try scalarToI16(input) },
        .i32 => .{ .i32 = switch (input) {
            .u32 => |wide| @bitCast(wide),
            .i64 => |wide| @truncate(wide),
            .index => |wide| @truncate(wide),
            else => try scalarToI32(input),
        } },
        .u8 => .{ .u8 = try scalarToU8(input) },
        .u16 => .{ .u16 = try scalarToU16(input) },
        .u32 => .{ .u32 = switch (input) {
            .i32 => |wide| @bitCast(wide),
            .i64 => |wide| @truncate(@as(u64, @bitCast(wide))),
            .index => |wide| @truncate(@as(u64, @bitCast(wide))),
            else => try scalarToU32(input),
        } },
        .i64 => .{ .i64 = switch (input) {
            .u64 => |wide| @bitCast(wide),
            else => try scalarToI64(input),
        } },
        .u64 => .{ .u64 = switch (input) {
            .i32 => |wide| @bitCast(@as(i64, wide)),
            .i64 => |wide| @bitCast(wide),
            .index => |wide| @bitCast(wide),
            else => try scalarToU64(input),
        } },
        .f16 => .{ .f16 = try scalarToF16(input) },
        .bf16 => .{ .bf16 = Bf16.fromF32(try scalarToF32(input)) },
        .f32 => .{ .f32 = try scalarToF32(input) },
        .f64 => .{ .f64 = try scalarToF64(input) },
    };
}

fn scalarToMask(input: Scalar) EvalError!u32 {
    return switch (input) {
        .i8 => |v| @bitCast(@as(i32, v)),
        .u8 => |v| v,
        .i16 => |v| @bitCast(@as(i32, v)),
        .u16 => |v| v,
        .i32 => |v| @bitCast(v),
        .u32 => |v| v,
        .u64 => |v| std.math.cast(u32, v) orelse return error.Overflow,
        .i64 => |v| std.math.cast(u32, v) orelse return error.Overflow,
        .index => |v| std.math.cast(u32, v) orelse return error.Overflow,
        else => error.UnsupportedType,
    };
}

fn scalarToBool(input: Scalar) EvalError!bool {
    return switch (input) {
        .bool => |v| v,
        else => error.UnsupportedType,
    };
}

fn scalarToI8(input: Scalar) EvalError!i8 {
    return switch (input) {
        .i8 => |v| v,
        .u8 => |v| @bitCast(v),
        .i16 => |v| @truncate(v),
        .u16 => |v| @bitCast(@as(u8, @truncate(v))),
        .i32 => |v| @truncate(v),
        .u32 => |v| @bitCast(@as(u8, @truncate(v))),
        .i64 => |v| @truncate(v),
        .u64 => |v| @bitCast(@as(u8, @truncate(v))),
        .index => |v| @truncate(v),
        .bool => |v| if (v) 1 else 0,
        .f16 => |v| @intFromFloat(v),
        .bf16 => |v| @intFromFloat(v.toF32()),
        .f32 => |v| @intFromFloat(v),
        .f64 => |v| @intFromFloat(v),
    };
}

fn scalarToI16(input: Scalar) EvalError!i16 {
    return switch (input) {
        .i8 => |v| v,
        .u8 => |v| v,
        .i16 => |v| v,
        .u16 => |v| @bitCast(v),
        .i32 => |v| @truncate(v),
        .u32 => |v| @bitCast(@as(u16, @truncate(v))),
        .i64 => |v| @truncate(v),
        .u64 => |v| @bitCast(@as(u16, @truncate(v))),
        .index => |v| @truncate(v),
        .bool => |v| if (v) 1 else 0,
        .f16 => |v| @intFromFloat(v),
        .bf16 => |v| @intFromFloat(v.toF32()),
        .f32 => |v| @intFromFloat(v),
        .f64 => |v| @intFromFloat(v),
    };
}

fn scalarToI32(input: Scalar) EvalError!i32 {
    return std.math.cast(i32, try scalarToI64(input)) orelse error.Overflow;
}

fn scalarToU8(input: Scalar) EvalError!u8 {
    return switch (input) {
        .i8 => |v| @bitCast(v),
        .u8 => |v| v,
        .i16 => |v| @truncate(@as(u16, @bitCast(v))),
        .u16 => |v| @truncate(v),
        .i32 => |v| @truncate(@as(u32, @bitCast(v))),
        .u32 => |v| @truncate(v),
        .i64 => |v| @truncate(@as(u64, @bitCast(v))),
        .u64 => |v| @truncate(v),
        .index => |v| @truncate(@as(u64, @bitCast(v))),
        .bool => |v| if (v) 1 else 0,
        .f16 => |v| @intFromFloat(v),
        .bf16 => |v| @intFromFloat(v.toF32()),
        .f32 => |v| @intFromFloat(v),
        .f64 => |v| @intFromFloat(v),
    };
}

fn scalarToU16(input: Scalar) EvalError!u16 {
    return switch (input) {
        .i8 => |v| @bitCast(@as(i16, v)),
        .u8 => |v| v,
        .i16 => |v| @bitCast(v),
        .u16 => |v| v,
        .i32 => |v| @truncate(@as(u32, @bitCast(v))),
        .u32 => |v| @truncate(v),
        .i64 => |v| @truncate(@as(u64, @bitCast(v))),
        .u64 => |v| @truncate(v),
        .index => |v| @truncate(@as(u64, @bitCast(v))),
        .bool => |v| if (v) 1 else 0,
        .f16 => |v| @intFromFloat(v),
        .bf16 => |v| @intFromFloat(v.toF32()),
        .f32 => |v| @intFromFloat(v),
        .f64 => |v| @intFromFloat(v),
    };
}

fn scalarToU32(input: Scalar) EvalError!u32 {
    return switch (input) {
        .i8 => |v| @bitCast(@as(i32, v)),
        .u8 => |v| v,
        .i16 => |v| @bitCast(@as(i32, v)),
        .u16 => |v| v,
        .u32 => |v| v,
        .i32 => |v| @bitCast(v),
        .u64 => |v| std.math.cast(u32, v) orelse error.Overflow,
        else => std.math.cast(u32, try scalarToI64(input)) orelse error.Overflow,
    };
}

fn scalarToI64(input: Scalar) EvalError!i64 {
    return switch (input) {
        .bool => |v| if (v) 1 else 0,
        .index => |v| v,
        .i8 => |v| v,
        .i16 => |v| v,
        .i32 => |v| v,
        .u8 => |v| v,
        .u16 => |v| v,
        .u32 => |v| v,
        .i64 => |v| v,
        .u64 => |v| std.math.cast(i64, v) orelse error.Overflow,
        .f16 => |v| @intFromFloat(v),
        .bf16 => |v| @intFromFloat(v.toF32()),
        .f32 => |v| @intFromFloat(v),
        .f64 => |v| @intFromFloat(v),
    };
}

fn scalarToU64(input: Scalar) EvalError!u64 {
    return switch (input) {
        .bool => |v| if (v) 1 else 0,
        .index => |v| @bitCast(v),
        .i8 => |v| @bitCast(@as(i64, v)),
        .i16 => |v| @bitCast(@as(i64, v)),
        .i32 => |v| @bitCast(@as(i64, v)),
        .u8 => |v| v,
        .u16 => |v| v,
        .u32 => |v| v,
        .i64 => |v| @bitCast(v),
        .u64 => |v| v,
        .f16 => |v| @intFromFloat(v),
        .bf16 => |v| @intFromFloat(v.toF32()),
        .f32 => |v| @intFromFloat(v),
        .f64 => |v| @intFromFloat(v),
    };
}

fn scalarToF16(input: Scalar) EvalError!f16 {
    return @floatCast(try scalarToF32(input));
}

fn scalarToF32(input: Scalar) EvalError!f32 {
    return switch (input) {
        .bool => |v| if (v) 1.0 else 0.0,
        .index => |v| @floatFromInt(v),
        .i8 => |v| @floatFromInt(v),
        .i16 => |v| @floatFromInt(v),
        .i32 => |v| @floatFromInt(v),
        .u8 => |v| @floatFromInt(v),
        .u16 => |v| @floatFromInt(v),
        .u32 => |v| @floatFromInt(v),
        .i64 => |v| @floatFromInt(v),
        .u64 => |v| @floatFromInt(v),
        .f16 => |v| v,
        .bf16 => |v| v.toF32(),
        .f32 => |v| v,
        .f64 => |v| @floatCast(v),
    };
}

fn scalarToF64(input: Scalar) EvalError!f64 {
    return switch (input) {
        .bool => |v| if (v) 1.0 else 0.0,
        .index => |v| @floatFromInt(v),
        .i8 => |v| @floatFromInt(v),
        .i16 => |v| @floatFromInt(v),
        .i32 => |v| @floatFromInt(v),
        .u8 => |v| @floatFromInt(v),
        .u16 => |v| @floatFromInt(v),
        .u32 => |v| @floatFromInt(v),
        .i64 => |v| @floatFromInt(v),
        .u64 => |v| @floatFromInt(v),
        .f16 => |v| v,
        .bf16 => |v| v.toF32(),
        .f32 => |v| v,
        .f64 => |v| v,
    };
}
