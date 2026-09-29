const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const artifact = @import("../root.zig").artifact;
const boundary = @import("../root.zig").signature;
const contract = @import("../root.zig").contract;
const interface = @import("../root.zig").interface;
const encoding = @import("encoding/root.zig");
const registers = @import("registers/root.zig");
const disasm = @import("disassemble/root.zig");
const sys = @import("sys");
const control = @import("root.zig").control;
const placement = @import("root.zig").placement;
const diagnostics = @import("../../root.zig").diagnostics;

const Allocator = std.mem.Allocator;
const BackendError = interface.BackendError;
const ExecuteResult = interface.ExecuteResult;
const ArithDialect = dialects.ArithDialect;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const GPR = registers.GPR;
const Instruction = encoding.Instruction;

pub const supports_native_execution = sys.capabilities.current.supportsAarch64Execution();

pub const max_arguments: usize = 8;
pub const max_results: usize = 1;

pub const Backend = struct {
    allocator: Allocator,
    ctx: *ir.Context,
    compiled_module: ?*ir.Operation = null,

    pub fn init(allocator: Allocator, ctx: *ir.Context) Allocator.Error!Backend {
        try contract.loadArithDialect(ctx);
        return .{
            .allocator = allocator,
            .ctx = ctx,
        };
    }

    pub fn deinit(_: *Backend) void {}

    pub fn verify(_: *Backend, module: *ir.Operation) BackendError!void {
        try contract.verifyModule("backend/aarch64/verify", module);
        _ = module.walk(.{ .order = .pre_order }, {}, refuseOverflow) catch
            return error.UnsupportedOperation;
    }

    pub fn lower(self: *Backend, module: *ir.Operation) BackendError!*ir.Operation {
        try self.verify(module);
        return module;
    }

    pub fn compile(self: *Backend, module: *ir.Operation) BackendError!void {
        self.compiled_module = try self.lower(module);
    }

    pub fn compileFunctionToMachineCode(
        self: *Backend,
        module: *ir.Operation,
        function_name: []const u8,
    ) BackendError![]u8 {
        const lowered = try self.lower(module);
        const func = ir.inspection.functionDefinitionByName(lowered, function_name) orelse return BackendError.FunctionNotFound;

        var emitter = Emitter.init(self.allocator);
        defer emitter.deinit();
        try emitter.emitFunction(func);

        const code = emitter.code.items;
        if (code.len == 0) return BackendError.CodeGenFailed;
        return self.allocator.dupe(u8, code) catch BackendError.OutOfMemory;
    }

    pub fn compileFunctionToArtifact(
        self: *Backend,
        module: *ir.Operation,
        function_name: []const u8,
    ) BackendError!artifact.Artifact {
        const func = ir.inspection.functionDefinitionByName(module, function_name) orelse
            return BackendError.FunctionNotFound;
        const signature = boundary.ofFunction(func) catch return BackendError.UnsupportedOperation;
        const code = try self.compileFunctionToMachineCode(module, function_name);
        defer self.allocator.free(code);

        return artifact.machineCodeArtifact(
            self.allocator,
            .{
                .architecture = .aarch64,
                .triple = "aarch64-unknown-unknown",
                .cpu = "generic",
            },
            .{
                .name = "AAPCS64",
                .calling_convention = "aapcs64",
                .pointer_width_bits = 64,
                .endianness = .little,
            },
            function_name,
            signature,
            code,
            &.{},
            &.{},
        ) catch BackendError.OutOfMemory;
    }

    pub fn emitFunction(self: *Backend, module: *ir.Operation, function_name: []const u8) BackendError![]u8 {
        return self.compileFunctionToMachineCode(module, function_name);
    }

    pub fn emit(
        self: *Backend,
        module: *ir.Operation,
        options: interface.EmitOptions,
        writer: *std.Io.Writer,
    ) BackendError!void {
        const entry = options.entry orelse return BackendError.FunctionNotFound;
        const code = try self.compileFunctionToMachineCode(module, entry);
        defer self.allocator.free(code);
        writer.writeAll(code) catch return BackendError.CodeGenFailed;
    }

    pub fn executeJit(self: *Backend, entry: []const u8, args: []const i64) BackendError!ExecuteResult {
        if (!supports_native_execution) return BackendError.UnsupportedArchitecture;

        const module = self.compiled_module orelse return BackendError.NoCompiledModule;
        const func = ir.inspection.functionDefinitionByName(module, entry) orelse return BackendError.FunctionNotFound;
        const function = FuncDialect.FuncOp{ .op = func };
        if (args.len != function.getNumArguments()) {
            return refuse(func, "aarch64 call argument count does not match the function signature", BackendError.ExecutionFailed);
        }
        const code = try self.compileFunctionToMachineCode(module, entry);
        defer self.allocator.free(code);

        return executeMachineCode(code, args, function.getNumResults() != 0);
    }

    pub fn disassemble(_: *Backend, code: []const u8, writer: *std.Io.Writer) BackendError!void {
        if (code.len % Instruction.size != 0) return BackendError.CodeGenFailed;

        var offset: usize = 0;
        while (offset < code.len) : (offset += Instruction.size) {
            if (offset != 0) writer.writeByte('\n') catch return BackendError.CodeGenFailed;
            const raw = std.mem.readInt(u32, code[offset..][0..4], .little);
            var buf: [96]u8 = undefined;
            const text = disasm.formatInstructionRawWithDetail(raw, &buf, true);
            writer.writeAll(text) catch return BackendError.CodeGenFailed;
        }
    }
};

/// Refuse overflow roots even when their results are unused or outside the selected function.
fn refuseOverflow(_: void, op: *ir.Operation) error{UnsupportedOperation}!ir.WalkResult {
    inline for (.{ ArithDialect.AddoOp, ArithDialect.SuboOp, ArithDialect.MuloOp }) |Op| {
        if (std.mem.eql(u8, op.name.name, Op.operation_name)) return error.UnsupportedOperation;
    }
    return .advance;
}

pub fn initHandle(allocator: Allocator, ctx: *ir.Context) BackendError!interface.BackendHandle {
    return interface.initHandle(
        Backend,
        allocator,
        ctx,
        interface.BackendTarget.aarch64,
        "aarch64",
        .{
            .artifact = .{ .machine_code = true },
            .cpu = .{ .disassemble = true },
        },
    );
}

const Emitter = struct {
    allocator: Allocator,
    code: std.ArrayListUnmanaged(u8) = .empty,
    plan: placement.Plan = .{},

    fn init(allocator: Allocator) Emitter {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Emitter) void {
        self.code.deinit(self.allocator);
    }

    /// Emits the verified finite block in order, including unused effects.
    fn emitFunction(self: *Emitter, func: *ir.Operation) BackendError!void {
        const function = FuncDialect.FuncOp{ .op = func };
        if (!function.hasBody() or function.getBody().blocks.size != 1) {
            return refuse(func, "aarch64 emission requires a single defined block", BackendError.UnsupportedOperation);
        }
        if (function.getNumArguments() > max_arguments) {
            return refuse(func, std.fmt.comptimePrint("aarch64 emission exceeds {d} arguments", .{max_arguments}), BackendError.UnsupportedOperation);
        }
        if (function.getNumResults() > max_results) {
            return refuse(func, std.fmt.comptimePrint("aarch64 emission exceeds {d} result", .{max_results}), BackendError.UnsupportedOperation);
        }
        self.plan.build(function.getEntryBlock()) catch |err| {
            const message = switch (err) {
                error.ValueCapacity => std.fmt.comptimePrint("aarch64 placement exceeds {d} tracked values", .{placement.max_values}),
                error.FrameCapacity => std.fmt.comptimePrint("aarch64 placement exceeds {d} frame slots", .{placement.max_frame_slots}),
                error.OperationCapacity => std.fmt.comptimePrint("aarch64 placement exceeds {d} operations", .{placement.max_operations}),
                error.ControlShape => "aarch64 structured control requires matching single-block regions and terminal yield/condition",
                error.ControlType => "aarch64 structured control requires scalar integer values, bool conditions and index induction",
                error.CarriedCapacity => std.fmt.comptimePrint("aarch64 control exceeds {d} carried or region-result values", .{control.max_carried_values}),
                error.DepthCapacity => std.fmt.comptimePrint("aarch64 control exceeds {d} nested constructs", .{control.max_depth}),
                error.MissingValue => "aarch64 operand has no preceding definition",
            };
            return refuse(self.plan.refused_operation.?, message, BackendError.UnsupportedOperation);
        };
        if (self.plan.frameBytes() != 0) {
            try self.emitInstruction(encoding.AddSubImmediate.sub(registers.SP.encoded, registers.SP.encoded, @intCast(self.plan.frameBytes()), .x));
        }
        for (function.getArguments(), 0..) |arg, index| {
            try self.normalize(argumentRegister(@intCast(index)), try scalarIntegerKind(func, arg.type));
        }
        for (function.getResultTypes()) |typ| _ = try scalarIntegerKind(func, typ);

        try self.emitSchedule(function);
    }

    const ControlFrame = struct {
        op: *ir.Operation,
        header: usize = 0,
        branch: usize = 0,
        merge: usize = 0,
        condition: ?*ir.Operation = null,
    };

    /// The placement schedule owns nesting. Emission has no recursive calls.
    fn emitSchedule(self: *Emitter, function: FuncDialect.FuncOp) BackendError!void {
        var frames: [control.max_depth]ControlFrame = undefined;
        for (self.plan.events[0..self.plan.event_count]) |event| {
            const op = event.op;
            if (event.kind == .next_region) {
                const frame = &frames[event.depth];
                switch (control.kind(op).?) {
                    .conditional => {
                        frame.merge = try self.branch();
                        try self.patchBranch(op, frame.branch, self.code.items.len, .eq);
                    },
                    .repeated => {
                        const condition = frame.condition.?;
                        const value = try self.location(condition, condition.operands.items[0].value, .x16);
                        try self.emitInstruction(encoding.AddSubImmediate.cmpImm(value.encode(), 0, .x));
                        frame.branch = try self.branch();
                        try self.transfer(condition, condition.getOperandValues()[1..], .{ .arguments = op.regions.items[1].getEntryBlock().?.arguments.items });
                    },
                    .counted => unreachable,
                }
                continue;
            }
            if (event.kind == .end) {
                const frame = &frames[event.depth];
                switch (control.kind(op).?) {
                    .conditional => try self.patchBranch(op, if (op.regions.items.len == 1) frame.branch else frame.merge, self.code.items.len, if (op.regions.items.len == 1) .eq else null),
                    .counted => {
                        try self.jump(op, frame.header);
                        try self.patchBranch(op, frame.branch, self.code.items.len, .ge);
                        const block = op.regions.items[0].getEntryBlock().?;
                        try self.transfer(op, block.arguments.items[1..], .{ .results = op.results.items });
                    },
                    .repeated => {
                        try self.jump(op, frame.header);
                        try self.patchBranch(op, frame.branch, self.code.items.len, .eq);
                        const condition = frame.condition.?;
                        try self.transfer(condition, condition.getOperandValues()[1..], .{ .results = op.results.items });
                    },
                }
                continue;
            }
            if (control.kind(op)) |construct| {
                const frame = &frames[event.depth];
                frame.* = .{ .op = op };
                switch (construct) {
                    .conditional => {
                        const value = try self.location(op, op.operands.items[0].value, .x16);
                        try self.emitInstruction(encoding.AddSubImmediate.cmpImm(value.encode(), 0, .x));
                        frame.branch = try self.branch();
                    },
                    .counted => {
                        const block = op.regions.items[0].getEntryBlock().?;
                        var sources: [control.max_transfers]*ir.Value = undefined;
                        sources[0] = op.operands.items[0].value;
                        for (op.operands.items[3..], 1..) |operand, index| sources[index] = operand.value;
                        try self.transfer(op, sources[0..block.arguments.items.len], .{ .arguments = block.arguments.items });
                        frame.header = self.code.items.len;
                        const iv = try self.location(op, block.arguments.items[0], .x16);
                        const upper = try self.location(op, op.operands.items[1].value, .x17);
                        try self.emitInstruction(encoding.AddSubShiftedRegister.cmpReg(iv.encode(), upper.encode(), .x));
                        frame.branch = try self.branch();
                    },
                    .repeated => {
                        try self.transfer(op, op.getOperandValues(), .{ .arguments = op.regions.items[0].getEntryBlock().?.arguments.items });
                        frame.header = self.code.items.len;
                    },
                }
                continue;
            }
            if (control.is(op, dialects.ScfDialect.YieldOp.operation_name)) {
                if (event.depth == 0) return refuse(op, "aarch64 yield requires a structured region", BackendError.UnsupportedOperation);
                const parent = frames[event.depth - 1].op;
                if (op.next_op != null) return refuse(op, "aarch64 yield must terminate its region", BackendError.UnsupportedOperation);
                switch (control.kind(parent).?) {
                    .conditional => try self.transfer(op, op.getOperandValues(), .{ .results = parent.results.items }),
                    .counted => {
                        const block = parent.regions.items[0].getEntryBlock().?;
                        try self.transfer(op, op.getOperandValues(), .{ .arguments = block.arguments.items[1..] });
                        const iv = block.arguments.items[0];
                        const value = try self.location(op, iv, .x16);
                        const step = try self.location(op, parent.operands.items[2].value, .x17);
                        const target = self.destination(iv);
                        try self.emitInstruction(encoding.AddSubShiftedRegister.addReg(target.encode(), value.encode(), step.encode(), .x));
                        try self.store(iv, target);
                    },
                    .repeated => {
                        const before = parent.regions.items[0].getEntryBlock().?;
                        if (op != control.last(parent.regions.items[1].getEntryBlock().?)) return refuse(op, "aarch64 while yield must terminate the after region", BackendError.UnsupportedOperation);
                        try self.transfer(op, op.getOperandValues(), .{ .arguments = before.arguments.items });
                    },
                }
                continue;
            }
            if (control.is(op, dialects.ScfDialect.ConditionOp.operation_name)) {
                if (event.depth == 0) return refuse(op, "aarch64 condition requires while before region", BackendError.UnsupportedOperation);
                const frame = &frames[event.depth - 1];
                if (control.kind(frame.op).? != .repeated or op != control.last(frame.op.regions.items[0].getEntryBlock().?)) return refuse(op, "aarch64 condition must terminate while before region", BackendError.UnsupportedOperation);
                frame.condition = op;
                continue;
            }
            if (control.is(op, FuncDialect.ReturnOp.operation_name)) {
                if (event.depth != 0 or op.next_op != null) return refuse(op, "aarch64 return must end the function block", BackendError.UnsupportedOperation);
                std.debug.assert(op.operands.items.len == function.getNumResults());
                if (op.operands.items.len == 1) {
                    const source = try self.location(op, op.operands.items[0].value, .x8);
                    try self.move(.x0, source);
                }
                if (self.plan.frameBytes() != 0) try self.emitInstruction(encoding.AddSubImmediate.add(registers.SP.encoded, registers.SP.encoded, @intCast(self.plan.frameBytes()), .x));
                try self.emitInstruction(encoding.UnconditionalBranchReg.retLr());
                return;
            }
            try self.emitOperation(op);
        }
        return refuse(function.op, "aarch64 function requires func.return", BackendError.UnsupportedOperation);
    }

    const Destinations = union(enum) {
        arguments: []const *ir.Value,
        results: []ir.Value,

        fn len(self: Destinations) usize {
            return switch (self) {
                .arguments => |values| values.len,
                .results => |values| values.len,
            };
        }

        fn at(self: Destinations, index: usize) *ir.Value {
            return switch (self) {
                .arguments => |values| values[index],
                .results => |values| &values[index],
            };
        }
    };

    /// Resolve parallel assignments before overwriting any source home.
    /// Each pass consumes a move or breaks a cycle, taking at most 2*N passes.
    fn transfer(self: *Emitter, op: *ir.Operation, sources: []const *ir.Value, destinations: Destinations) BackendError!void {
        std.debug.assert(sources.len == destinations.len());
        std.debug.assert(sources.len <= control.max_transfers);
        const Move = struct { source: placement.Location, target: placement.Location, pending: bool };
        var moves: [control.max_transfers]Move = undefined;
        var remaining: usize = 0;
        for (sources, 0..) |source, index| {
            const target = self.plan.get(destinations.at(index)).?;
            const home = try self.valueHome(op, source);
            const pending = target != .dead and !sameHome(home, target);
            moves[index] = .{ .source = home, .target = target, .pending = pending };
            remaining += @intFromBool(pending);
        }
        for (0..2 * control.max_transfers) |_| {
            if (remaining == 0) return;
            var progressed = false;
            for (moves[0..sources.len]) |*move_item| {
                if (!move_item.pending) continue;
                var blocked = false;
                for (moves[0..sources.len]) |other| {
                    if (other.pending and sameHome(move_item.target, other.source)) blocked = true;
                }
                if (blocked) continue;
                try self.copyHome(move_item.source, move_item.target, .x16);
                move_item.pending = false;
                remaining -= 1;
                progressed = true;
            }
            if (progressed) continue;
            for (moves[0..sources.len]) |move_item| {
                if (!move_item.pending) continue;
                try self.copyHome(move_item.source, .{ .register = .x8 }, .x16);
                for (moves[0..sources.len]) |*other| {
                    if (other.pending and sameHome(other.source, move_item.source)) other.source = .{ .register = .x8 };
                }
                break;
            }
        }
        unreachable;
    }

    fn sameHome(lhs: placement.Location, rhs: placement.Location) bool {
        return switch (lhs) {
            .register => |reg| rhs == .register and rhs.register == reg,
            .stack => |slot| rhs == .stack and rhs.stack == slot,
            .dead => rhs == .dead,
        };
    }

    fn valueHome(self: *Emitter, op: *ir.Operation, value: *ir.Value) BackendError!placement.Location {
        if (self.plan.get(value)) |result| return result;
        if (value.getOwnerBlock() == @as(*anyopaque, self.plan.entry_block.?) and value.kind.block_argument.arg_number < max_arguments) return .{ .register = argumentRegister(@intCast(value.kind.block_argument.arg_number)) };
        return refuse(op, "aarch64 operand has no placement", BackendError.CodeGenFailed);
    }

    fn copyHome(self: *Emitter, source: placement.Location, target: placement.Location, scratch: GPR) BackendError!void {
        const register = switch (source) {
            .register => |reg| reg,
            .stack => |slot| load: {
                try self.emitInstruction(encoding.LoadStoreRegImm.ldr(scratch.encode(), registers.SP.encoded, @intCast(slot), .x));
                break :load scratch;
            },
            .dead => unreachable,
        };
        switch (target) {
            .register => |reg| try self.move(reg, register),
            .stack => |slot| try self.emitInstruction(encoding.LoadStoreRegImm.str(register.encode(), registers.SP.encoded, @intCast(slot), .x)),
            .dead => unreachable,
        }
    }

    fn branch(self: *Emitter) BackendError!usize {
        const offset = self.code.items.len;
        try self.emitInstruction(encoding.UnconditionalBranchImm.b(0));
        return offset;
    }

    fn jump(self: *Emitter, op: *ir.Operation, target: usize) BackendError!void {
        const offset = try self.branch();
        try self.patchBranch(op, offset, target, null);
    }

    fn patchBranch(self: *Emitter, op: *ir.Operation, offset: usize, target: usize, condition: ?encoding.Condition) BackendError!void {
        std.debug.assert(offset % Instruction.size == 0);
        std.debug.assert(target % Instruction.size == 0);
        const distance = @divExact(@as(i64, @intCast(target)) - @as(i64, @intCast(offset)), Instruction.size);
        const inst = if (condition) |cond|
            encoding.ConditionalBranch.bCond(cond, std.math.cast(i19, distance) orelse return refuse(op, "aarch64 conditional branch exceeds signed 19-bit instruction displacement", BackendError.UnsupportedOperation))
        else
            encoding.UnconditionalBranchImm.b(std.math.cast(i26, distance) orelse return refuse(op, "aarch64 branch exceeds signed 26-bit instruction displacement", BackendError.UnsupportedOperation));
        inst.write(self.code.items[offset..][0..Instruction.size]);
    }

    const ScalarOp = enum {
        constant,
        add,
        sub,
        mul,
        div,
        rem,
        @"and",
        @"or",
        xor,
        not,
        shl,
        shr,
        ushr,
        cmp,
        select,
        min,
        max,
        abs,
        neg,
        cast,
        umulhi,
        popcount,
    };

    /// Reads temporary operands before writing a potentially recycled home.
    fn emitOperation(self: *Emitter, op: *ir.Operation) BackendError!void {
        const admitted = @import("root.zig").admission.lookup(op.name.name);
        if (admitted == null or admitted.?.status != .admitted) {
            return refuse(op, "aarch64 emission defers this operation", BackendError.UnsupportedOperation);
        }
        const operation = std.meta.stringToEnum(ScalarOp, op.name.name["arith.".len..]) orelse
            return refuse(op, "aarch64 emission defers this operation", BackendError.UnsupportedOperation);
        std.debug.assert(op.results.items.len == 1);
        const value = op.getResult(0).?;
        const kind = try scalarIntegerKind(op, value.type);
        for (op.operands.items) |operand| _ = try scalarIntegerKind(op, operand.value.type);
        if (operation == .constant) {
            const integer = (ArithDialect.ConstantOp{ .op = op }).getIntValue() orelse boolean: {
                const attr = op.getAttrAs(ir.Attribute.BoolAttr, "value") orelse
                    return refuse(op, "aarch64 constant requires an integer or boolean value", BackendError.UnsupportedOperation);
                break :boolean @as(i64, @intFromBool(attr.getValue()));
            };
            if (value.hasNoUses()) return;
            const target = self.destination(value);
            try self.emitMoveImmediate(target, @bitCast(integer));
            try self.normalize(target, kind);
            try self.store(value, target);
            return;
        }
        try self.legalScalar(op, operation, kind);
        const temporaries = [_]GPR{ .x16, .x17, .x8 };
        std.debug.assert(op.operands.items.len <= temporaries.len);
        for (op.operands.items, 0..) |operand, index| {
            const source = try self.location(op, operand.value, temporaries[index]);
            try self.move(temporaries[index], source);
        }
        try self.emitRequirements(op, operation, kind);
        if (value.hasNoUses()) return;
        const target = self.destination(value);
        const bits = dialects.arith.scalarBitWidth(kind);
        switch (operation) {
            .constant => unreachable,
            .add => try self.emitInstruction(encoding.AddSubShiftedRegister.addReg(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x)),
            .sub => try self.emitInstruction(encoding.AddSubShiftedRegister.subReg(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x)),
            .mul => try self.emitInstruction(encoding.DataProcessing3Source.mul(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x)),
            .div, .rem => {
                const quotient = if (operation == .rem) GPR.x8 else target;
                const inst = if (unsignedKind(kind))
                    encoding.DataProcessing2Source.udiv(quotient.encode(), GPR.x16.encode(), GPR.x17.encode(), .x)
                else
                    encoding.DataProcessing2Source.sdiv(quotient.encode(), GPR.x16.encode(), GPR.x17.encode(), .x);
                try self.emitInstruction(inst);
                if (operation == .rem) try self.emitInstruction(encoding.DataProcessing3Source.msub(target.encode(), quotient.encode(), GPR.x17.encode(), GPR.x16.encode(), .x));
            },
            .@"and" => try self.emitInstruction(encoding.LogicalShiftedRegister.andReg(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x)),
            .@"or" => try self.emitInstruction(encoding.LogicalShiftedRegister.orrReg(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x)),
            .xor => try self.emitInstruction(encoding.LogicalShiftedRegister.eorReg(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x)),
            .not => {
                try self.emitMoveImmediate(.x17, std.math.maxInt(u64));
                try self.emitInstruction(encoding.LogicalShiftedRegister.eorReg(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x));
            },
            .neg => try self.emitInstruction(encoding.AddSubShiftedRegister.subReg(target.encode(), registers.ZR.encoded, GPR.x16.encode(), .x)),
            .abs => {
                if (unsignedKind(kind)) {
                    try self.move(target, .x16);
                } else {
                    try self.emitInstruction(encoding.AddSubImmediate.cmpImm(GPR.x16.encode(), 0, .x));
                    try self.emitInstruction(encoding.AddSubShiftedRegister.subReg(GPR.x17.encode(), registers.ZR.encoded, GPR.x16.encode(), .x));
                    try self.emitInstruction(encoding.ConditionalSelect.csel(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .ge, .x));
                }
            },
            .shl, .shr, .ushr => {
                if (operation != .shl) try self.extend(.x16, bits, operation == .shr);
                var inst = encoding.DataProcessing2Source.udiv(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x);
                inst.data_processing_reg.data_proc_2src.opcode = switch (operation) {
                    .shl => .lslv,
                    .shr => .asrv,
                    .ushr => .lsrv,
                    else => unreachable,
                };
                try self.emitInstruction(inst);
            },
            .min, .max => {
                try self.emitInstruction(encoding.AddSubShiftedRegister.cmpReg(GPR.x16.encode(), GPR.x17.encode(), .x));
                const condition: encoding.Condition = if (unsignedKind(kind))
                    (if (operation == .min) .ls else .hs)
                else
                    (if (operation == .min) .le else .ge);
                try self.emitInstruction(encoding.ConditionalSelect.csel(target.encode(), GPR.x16.encode(), GPR.x17.encode(), condition, .x));
            },
            .select => {
                try self.emitInstruction(encoding.AddSubImmediate.cmpImm(GPR.x16.encode(), 0, .x));
                try self.emitInstruction(encoding.ConditionalSelect.csel(target.encode(), GPR.x17.encode(), GPR.x8.encode(), .ne, .x));
            },
            .cmp => {
                const predicate = (ArithDialect.CmpOp{ .op = op }).getPredicate().?;
                const operand_kind = try scalarIntegerKind(op, op.operands.items[0].value.type);
                const operand_bits = dialects.arith.scalarBitWidth(operand_kind);
                const signed = switch (predicate) {
                    .lt, .le, .gt, .ge, .slt, .sle, .sgt, .sge => true,
                    else => false,
                };
                try self.extend(.x16, operand_bits, signed);
                try self.extend(.x17, operand_bits, signed);
                try self.emitInstruction(encoding.AddSubShiftedRegister.cmpReg(GPR.x16.encode(), GPR.x17.encode(), .x));
                const condition: encoding.Condition = switch (predicate) {
                    .eq => .eq,
                    .ne => .ne,
                    .lt, .slt => .lt,
                    .le, .sle => .le,
                    .gt, .sgt => .gt,
                    .ge, .sge => .ge,
                    .ult => .lo,
                    .ule => .ls,
                    .ugt => .hi,
                    .uge => .hs,
                };
                try self.emitInstruction(encoding.ConditionalSelect.cset(target.encode(), condition, .x));
            },
            .cast => try self.move(target, .x16),
            .umulhi => {
                try self.extend(.x16, bits, false);
                try self.extend(.x17, bits, false);
                if (bits == 64) {
                    try self.emitInstruction(.{ .raw = 0x9bc07c00 | (@as(u32, @backingInt(GPR.x17)) << 16) | (@as(u32, @backingInt(GPR.x16)) << 5) | @as(u32, @backingInt(target)) });
                } else {
                    try self.emitInstruction(encoding.DataProcessing3Source.mul(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x));
                    try self.logicalRight(target, target, @intCast(bits));
                }
            },
            .popcount => try self.popcount(target, bits),
        }
        try self.normalize(target, kind);
        try self.store(value, target);
    }

    fn move(self: *Emitter, target: GPR, source: GPR) BackendError!void {
        if (target != source) try self.emitInstruction(encoding.LogicalShiftedRegister.movReg(target.encode(), source.encode(), .x));
    }

    fn isDivision(operation: ScalarOp) bool {
        return operation == .div or operation == .rem;
    }

    fn isShift(operation: ScalarOp) bool {
        return operation == .shl or operation == .shr or operation == .ushr;
    }

    fn unsignedKind(kind: dialects.arith.ScalarKind) bool {
        return dialects.arith.scalarKindIsUnsignedInteger(kind) or kind == .index;
    }

    /// Admission follows the dialect's complete scalar declaration.
    fn legalScalar(_: *Emitter, op: *ir.Operation, operation: ScalarOp, kind: dialects.arith.ScalarKind) BackendError!void {
        if (kind == .bool) switch (operation) {
            .@"and", .@"or", .xor, .not, .cmp, .select, .cast => {},
            else => return refuse(op, "aarch64 arithmetic requires an integer operand", BackendError.UnsupportedOperation),
        };
        if (operation == .cast) {
            const source = try scalarIntegerKind(op, op.operands.items[0].value.type);
            if ((source == .bool or kind == .bool) and source != kind) {
                return refuse(op, "aarch64 cast does not admit integer boolean conversions", BackendError.UnsupportedOperation);
            }
        }
        if (operation == .cmp) {
            const predicate = (ArithDialect.CmpOp{ .op = op }).getPredicate() orelse
                return refuse(op, "aarch64 comparison requires a predicate", BackendError.UnsupportedOperation);
            const source = try scalarIntegerKind(op, op.operands.items[0].value.type);
            if (source == .bool and predicate != .eq and predicate != .ne) {
                return refuse(op, "aarch64 boolean comparison requires eq or ne", BackendError.UnsupportedOperation);
            }
        }
    }

    /// UBFM Xd, Xn, #shift, #63 is a logical right shift.
    fn logicalRight(self: *Emitter, target: GPR, source: GPR, shift: u6) BackendError!void {
        try self.emitInstruction(.{ .raw = 0xd340fc00 | (@as(u32, shift) << 16) | (@as(u32, @backingInt(source)) << 5) | @as(u32, @backingInt(target)) });
    }

    /// Fixed SWAR reduction uses only the three caller-saved temporaries.
    fn popcount(self: *Emitter, target: GPR, bits: u8) BackendError!void {
        try self.extend(.x16, bits, false);
        try self.logicalRight(.x8, .x16, 1);
        try self.emitMoveImmediate(.x17, 0x5555555555555555);
        try self.emitInstruction(encoding.LogicalShiftedRegister.andReg(GPR.x8.encode(), GPR.x8.encode(), GPR.x17.encode(), .x));
        try self.emitInstruction(encoding.AddSubShiftedRegister.subReg(GPR.x16.encode(), GPR.x16.encode(), GPR.x8.encode(), .x));
        try self.logicalRight(.x8, .x16, 2);
        try self.emitMoveImmediate(.x17, 0x3333333333333333);
        try self.emitInstruction(encoding.LogicalShiftedRegister.andReg(GPR.x8.encode(), GPR.x8.encode(), GPR.x17.encode(), .x));
        try self.emitInstruction(encoding.LogicalShiftedRegister.andReg(GPR.x16.encode(), GPR.x16.encode(), GPR.x17.encode(), .x));
        try self.emitInstruction(encoding.AddSubShiftedRegister.addReg(GPR.x16.encode(), GPR.x16.encode(), GPR.x8.encode(), .x));
        try self.logicalRight(.x8, .x16, 4);
        try self.emitInstruction(encoding.AddSubShiftedRegister.addReg(GPR.x16.encode(), GPR.x16.encode(), GPR.x8.encode(), .x));
        try self.emitMoveImmediate(.x17, 0x0f0f0f0f0f0f0f0f);
        try self.emitInstruction(encoding.LogicalShiftedRegister.andReg(GPR.x16.encode(), GPR.x16.encode(), GPR.x17.encode(), .x));
        inline for (.{ 8, 16, 32 }) |shift| {
            try self.logicalRight(.x8, .x16, shift);
            try self.emitInstruction(encoding.AddSubShiftedRegister.addReg(GPR.x16.encode(), GPR.x16.encode(), GPR.x8.encode(), .x));
        }
        try self.extend(.x16, 7, false);
        try self.move(target, .x16);
    }

    /// Seven facts are the scalar dialect's six entries plus its one result.
    const max_scalar_facts = 7;

    fn emitRequirements(self: *Emitter, op: *ir.Operation, operation: ScalarOp, kind: dialects.arith.ScalarKind) BackendError!void {
        const facts = ir.interfaces.effects;
        var storage: [max_scalar_facts]facts.Fact = undefined;
        const declaration = facts.collectInto(op, &storage) catch
            return refuse(op, "aarch64 scalar effect declaration cannot be collected", BackendError.UnsupportedOperation);
        if (!declaration.complete) return refuse(op, "aarch64 scalar effect declaration is incomplete", BackendError.UnsupportedOperation);
        const bits = dialects.arith.scalarBitWidth(kind);
        for (declaration.records) |record| switch (record) {
            .requirement => |requirement| switch (requirement.kind) {
                .nonzero => {
                    if (literalInteger(op.operands.items[1].value)) |rhs| {
                        if (dialects.arith.scalar.maskToBits(rhs, bits) == 0) return refuse(op, "aarch64 DivisionByZero is statically certain", BackendError.UnsupportedOperation);
                    }
                    try self.emitInstruction(encoding.AddSubImmediate.cmpImm(GPR.x17.encode(), 0, .x));
                    try self.requireCondition(.ne);
                },
                .quotient_representable => {
                    std.debug.assert(isDivision(operation));
                    const minimum: i64 = @intCast(dialects.arith.scalar.intLimits(bits).min);
                    if (literalInteger(op.operands.items[0].value)) |lhs| {
                        if (literalInteger(op.operands.items[1].value)) |rhs| {
                            if (dialects.arith.scalar.truncate(lhs, bits) == minimum and dialects.arith.scalar.truncate(rhs, bits) == -1) {
                                return refuse(op, "aarch64 SignedDivisionOverflow is statically certain", BackendError.UnsupportedOperation);
                            }
                        }
                    }
                    try self.emitMoveImmediate(.x8, @bitCast(minimum));
                    try self.emitInstruction(encoding.AddSubShiftedRegister.cmpReg(GPR.x16.encode(), GPR.x8.encode(), .x));
                    const skip = self.code.items.len;
                    try self.emitInstruction(encoding.ConditionalBranch.bCond(.ne, 0));
                    try self.emitMoveImmediate(.x8, std.math.maxInt(u64));
                    try self.emitInstruction(encoding.AddSubShiftedRegister.cmpReg(GPR.x17.encode(), GPR.x8.encode(), .x));
                    try self.requireCondition(.ne);
                    const distance: i19 = @intCast((self.code.items.len - skip) / Instruction.size);
                    encoding.ConditionalBranch.bCond(.ne, distance).write(self.code.items[skip..][0..Instruction.size]);
                },
                .in_bounds => {
                    std.debug.assert(isShift(operation));
                    if (literalInteger(op.operands.items[1].value)) |count| {
                        if (dialects.arith.scalar.shiftCount(count, bits) == null) return refuse(op, "aarch64 InvalidShiftAmount is statically certain", BackendError.UnsupportedOperation);
                    }
                    try self.emitInstruction(encoding.AddSubImmediate.cmpImm(GPR.x17.encode(), bits, .x));
                    try self.requireCondition(.lo);
                },
                else => return refuse(op, "aarch64 scalar requirement is unsupported", BackendError.UnsupportedOperation),
            },
            else => {},
        };
    }

    fn literalInteger(value: *ir.Value) ?i64 {
        const raw = value.getDefiningOp() orelse return null;
        const op: *ir.Operation = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, op.name.name, ArithDialect.ConstantOp.operation_name)) return null;
        return (ArithDialect.ConstantOp{ .op = op }).getIntValue();
    }

    /// AArch64 BRK #0 raises SIGTRAP on Linux. The successful edge skips it.
    fn requireCondition(self: *Emitter, condition: encoding.Condition) BackendError!void {
        try self.emitInstruction(encoding.ConditionalBranch.bCond(condition, 2));
        try self.emitInstruction(.{ .raw = 0xd4200000 });
    }

    fn location(self: *Emitter, op: *ir.Operation, value: *ir.Value, temporary: GPR) BackendError!GPR {
        const home = try self.valueHome(op, value);
        return switch (home) {
            .register => |register| register,
            .stack => |slot| blk: {
                std.debug.assert(slot < self.plan.frame_slots);
                try self.emitInstruction(encoding.LoadStoreRegImm.ldr(temporary.encode(), registers.SP.encoded, @intCast(slot), .x));
                break :blk temporary;
            },
            .dead => unreachable,
        };
    }

    fn destination(self: *const Emitter, value: *ir.Value) GPR {
        return switch (self.plan.get(value).?) {
            .register => |register| register,
            .stack => .x8,
            .dead => unreachable,
        };
    }

    fn store(self: *Emitter, value: *ir.Value, register: GPR) BackendError!void {
        switch (self.plan.get(value).?) {
            .stack => |slot| {
                std.debug.assert(slot < self.plan.frame_slots);
                try self.emitInstruction(encoding.LoadStoreRegImm.str(register.encode(), registers.SP.encoded, @intCast(slot), .x));
            },
            .register => |home| std.debug.assert(home == register),
            .dead => unreachable,
        }
    }

    /// SBFM/UBFM Xd, Xn, #0, #(width-1) extends the low declared bits.
    fn normalize(self: *Emitter, register: GPR, kind: dialects.arith.ScalarKind) BackendError!void {
        const scalar = dialects.arith.scalarDescriptor(kind);
        std.debug.assert(scalar.class != .float);
        std.debug.assert(scalar.bit_width > 0);
        std.debug.assert(scalar.bit_width <= 64);
        if (scalar.bit_width == 64) return;

        try self.extend(register, scalar.bit_width, scalar.class == .signed_integer);
    }

    fn extend(self: *Emitter, register: GPR, bits: u8, signed: bool) BackendError!void {
        std.debug.assert(bits > 0);
        std.debug.assert(bits <= 64);
        if (bits == 64) return;
        const opcode: u32 = if (signed) 0x93400000 else 0xd3400000;
        const encoded: u32 = @backingInt(register.encode());
        try self.emitInstruction(.{ .raw = opcode | (@as(u32, bits - 1) << 10) | (encoded << 5) | encoded });
    }

    fn emitMoveImmediate(self: *Emitter, target: GPR, value: u64) BackendError!void {
        if (value == 0) {
            try self.emitInstruction(encoding.MoveWide.movz(target.encode(), 0, 0, .x));
            return;
        }

        var first_chunk: ?u2 = null;
        for (0..4) |index| {
            const shift: u6 = @intCast(index * 16);
            const chunk: u16 = @truncate(value >> shift);
            if (chunk == 0) continue;
            const hw: u2 = @intCast(index);
            first_chunk = hw;
            try self.emitInstruction(encoding.MoveWide.movz(target.encode(), chunk, hw, .x));
            break;
        }

        const first = first_chunk orelse unreachable;
        for (0..4) |index| {
            const hw: u2 = @intCast(index);
            if (hw == first) continue;
            const shift: u6 = @intCast(index * 16);
            const chunk: u16 = @truncate(value >> shift);
            if (chunk == 0) continue;
            try self.emitInstruction(encoding.MoveWide.movk(target.encode(), chunk, hw, .x));
        }
    }

    fn emitInstruction(self: *Emitter, inst: Instruction) BackendError!void {
        const old_len = self.code.items.len;
        self.code.resize(self.allocator, old_len + Instruction.size) catch return BackendError.OutOfMemory;
        inst.write(self.code.items[old_len..][0..Instruction.size]);
    }
};

/// Publishes the refused operation's exact name and location in its diagnostic.
fn refuse(op: *ir.Operation, message: []const u8, err: BackendError) BackendError {
    var diagnostic = op.emitError(message);
    defer diagnostic.deinit();
    _ = diagnostic.emit() catch {};
    return err;
}

fn scalarIntegerKind(op: *ir.Operation, typ: ir.Type) BackendError!dialects.arith.ScalarKind {
    const name = typ.getDialectTypeName() orelse return refuse(op, "aarch64 emission requires a scalar integer type", BackendError.UnsupportedOperation);
    const kind = dialects.arith.scalarKindFromTypeName(name) orelse return refuse(op, "aarch64 emission requires a scalar integer type", BackendError.UnsupportedOperation);
    return switch (kind) {
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .index, .bool => kind,
        else => refuse(op, "aarch64 emission requires a scalar integer type", BackendError.UnsupportedOperation),
    };
}

fn argumentRegister(index: u3) GPR {
    return switch (index) {
        0 => .x0,
        1 => .x1,
        2 => .x2,
        3 => .x3,
        4 => .x4,
        5 => .x5,
        6 => .x6,
        7 => .x7,
    };
}

fn executeMachineCode(code: []const u8, args: []const i64, has_result: bool) BackendError!ExecuteResult {
    std.debug.assert(args.len <= max_arguments);
    std.debug.assert(code.len > 0);

    var memory = sys.memory.mapAnonymous(code.len, .{ .read = true, .write = true }) catch return BackendError.ExecutionFailed;
    defer sys.memory.unmap(memory);

    @memcpy(memory[0..code.len], code);
    sys.memory.protect(memory, .{ .read = true, .execute = true }) catch return BackendError.ExecutionFailed;

    if (has_result) return .{ .int = invokeMachineCode(i64, memory.ptr, args) };
    invokeMachineCode(void, memory.ptr, args);
    return .void_;
}

fn invokeMachineCode(comptime Result: type, address: [*]u8, args: []const i64) Result {
    std.debug.assert(args.len <= max_arguments);
    return switch (args.len) {
        0 => blk: {
            const func: *const fn () callconv(.c) Result = @ptrCast(@alignCast(address));
            break :blk func();
        },
        1 => blk: {
            const func: *const fn (i64) callconv(.c) Result = @ptrCast(@alignCast(address));
            break :blk func(args[0]);
        },
        2 => blk: {
            const func: *const fn (i64, i64) callconv(.c) Result = @ptrCast(@alignCast(address));
            break :blk func(args[0], args[1]);
        },
        3 => blk: {
            const func: *const fn (i64, i64, i64) callconv(.c) Result = @ptrCast(@alignCast(address));
            break :blk func(args[0], args[1], args[2]);
        },
        4 => blk: {
            const func: *const fn (i64, i64, i64, i64) callconv(.c) Result = @ptrCast(@alignCast(address));
            break :blk func(args[0], args[1], args[2], args[3]);
        },
        5 => blk: {
            const func: *const fn (i64, i64, i64, i64, i64) callconv(.c) Result = @ptrCast(@alignCast(address));
            break :blk func(args[0], args[1], args[2], args[3], args[4]);
        },
        6 => blk: {
            const func: *const fn (i64, i64, i64, i64, i64, i64) callconv(.c) Result = @ptrCast(@alignCast(address));
            break :blk func(args[0], args[1], args[2], args[3], args[4], args[5]);
        },
        7 => blk: {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64) callconv(.c) Result = @ptrCast(@alignCast(address));
            break :blk func(args[0], args[1], args[2], args[3], args[4], args[5], args[6]);
        },
        8 => blk: {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) Result = @ptrCast(@alignCast(address));
            break :blk func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]);
        },
        else => unreachable,
    };
}

fn makeConstantReturnModule(ctx: *ir.Context, value: i64) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(ctx, loc);
    var func = try FuncDialect.FuncOp.create(ctx, loc, "ret_const", &.{}, &.{i64_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, value);
    try entry.addOperation(c.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{c.getResult()});
    try entry.addOperation(ret.op);

    return module.op;
}

fn makeAddArgsModule(ctx: *ir.Context) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(ctx, loc);
    var func = try FuncDialect.FuncOp.create(ctx, loc, "add_args", &.{ i64_type, i64_type }, &.{i64_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    var add = try ArithDialect.AddOp.create(ctx, loc, func.getArgument(0), func.getArgument(1));
    try entry.addOperation(add.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{add.getResult()});
    try entry.addOperation(ret.op);

    return module.op;
}

test "aarch64 backend handle exposes artifacts and debug" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);

    var handle = try initHandle(allocator, &ctx);
    defer handle.deinit();

    try std.testing.expect(interface.BackendTarget.aarch64.eql(handle.target));
    try std.testing.expect(handle.capabilities.artifact.machine_code);
    try std.testing.expect(handle.capabilities.cpu.disassemble);
}

test "aarch64 backend emits golden scalar constant return" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);

    const module = try makeConstantReturnModule(&ctx, 42);
    var backend = try Backend.init(allocator, &ctx);
    defer backend.deinit();

    const code = try backend.compileFunctionToMachineCode(module, "ret_const");
    defer allocator.free(code);

    const expected = [_]u8{
        0x49, 0x05, 0x80, 0xd2,
        0xe0, 0x03, 0x09, 0xaa,
        0xc0, 0x03, 0x5f, 0xd6,
    };
    try std.testing.expectEqualSlices(u8, &expected, code);
}

test "aarch64 backend emits add of two AAPCS64 integer arguments" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);

    const module = try makeAddArgsModule(&ctx);
    var backend = try Backend.init(allocator, &ctx);
    defer backend.deinit();

    const code = try backend.compileFunctionToMachineCode(module, "add_args");
    defer allocator.free(code);

    const expected = [_]u8{
        0xf0, 0x03, 0x00, 0xaa,
        0xf1, 0x03, 0x01, 0xaa,
        0x09, 0x02, 0x11, 0x8b,
        0xe0, 0x03, 0x09, 0xaa,
        0xc0, 0x03, 0x5f, 0xd6,
    };
    try std.testing.expectEqualSlices(u8, &expected, code);
}

test "aarch64 backend disassembles the scalar subset" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);

    const module = try makeConstantReturnModule(&ctx, 42);
    var backend = try Backend.init(allocator, &ctx);
    defer backend.deinit();

    const code = try backend.compileFunctionToMachineCode(module, "ret_const");
    defer allocator.free(code);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try backend.disassemble(code, &writer);

    try std.testing.expectEqualStrings(
        "movz x9, #0x2a\nmov x0, x9\nret",
        writer.buffered(),
    );
}

test "aarch64 backend records machine-code artifact metadata" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);

    const module = try makeConstantReturnModule(&ctx, 42);
    var backend = try Backend.init(allocator, &ctx);
    defer backend.deinit();

    var out = try backend.compileFunctionToArtifact(module, "ret_const");
    defer out.deinit();

    try std.testing.expectEqual(artifact.ArtifactKind.machine_code, out.metadata.kind);
    try std.testing.expectEqual(artifact.Architecture.aarch64, out.metadata.target.architecture);
    try std.testing.expectEqual(@as(u16, 64), out.metadata.abi.pointer_width_bits.?);
    try std.testing.expectEqual(artifact.BufferFormat.machine_code, out.payload.buffers.items[0].format);
}

test "aarch64 native execution runs only on AArch64 hosts" {
    if (!supports_native_execution) return error.SkipZigTest;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);

    const module = try makeAddArgsModule(&ctx);
    var backend = try Backend.init(allocator, &ctx);
    defer backend.deinit();

    const result = try compileAndRun(&backend, module, "add_args", &.{ 40, 2 });
    try std.testing.expectEqual(@as(i64, 42), result.asInt().?);
}

/// Keep execution witnesses behind this seam for the subsequent runtime contract unit.
fn compileAndRun(
    backend: *Backend,
    module: *ir.Operation,
    entry: []const u8,
    args: []const i64,
) !ExecuteResult {
    try backend.compile(module);
    return backend.executeJit(entry, args);
}

const Witness = struct {
    arena: alloc_arena.Arena,
    ctx: ir.Context,
    backend: Backend,
    module: *ir.Operation,
    function: FuncDialect.FuncOp,
    diagnostic_operation: []const u8 = "",
    diagnostic_message: []const u8 = "",

    fn init(self: *Witness, kind: dialects.arith.ScalarKind, arguments: usize, results: usize) !void {
        return self.initSignature(kind, kind, arguments, results);
    }

    fn initSignature(self: *Witness, argument_kind: dialects.arith.ScalarKind, kind: dialects.arith.ScalarKind, arguments: usize, results: usize) !void {
        self.arena = alloc_arena.Arena.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        self.ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        try dialects.registerAllDialects(&self.ctx);
        self.backend = try Backend.init(allocator, &self.ctx);
        self.diagnostic_operation = "";
        self.diagnostic_message = "";
        _ = try self.ctx.registerDiagnosticHandler(.{ .context = self, .handle = recordDiagnostic });
        const typ = try ArithDialect.getScalarType(&self.ctx, kind);
        var types: [max_arguments + 1]ir.Type = @splat(typ);
        var argument_types: [max_arguments + 1]ir.Type = @splat(try ArithDialect.getScalarType(&self.ctx, argument_kind));
        std.debug.assert(arguments <= types.len);
        std.debug.assert(results <= types.len);
        const module = try BuiltinDialect.ModuleOp.create(&self.ctx, .unknown);
        self.module = module.op;
        self.function = try FuncDialect.FuncOp.create(&self.ctx, .unknown, "witness", argument_types[0..arguments], types[0..results]);
        try module.getBodyBlock().addOperation(self.function.op);
    }

    fn deinit(self: *Witness) void {
        self.backend.deinit();
        self.ctx.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    fn recordDiagnostic(context: ?*anyopaque, diagnostic: *const diagnostics.Diagnostic) !diagnostics.HandlerResult {
        const self: *Witness = @ptrCast(@alignCast(context.?));
        self.diagnostic_operation = diagnostic.operationName() orelse "";
        self.diagnostic_message = diagnostic.message;
        return .consumed;
    }

    fn constant(self: *Witness, value: i64) !*ir.Value {
        const typ = self.function.getResultTypes()[0];
        var op = try ArithDialect.ConstantOp.createInt(&self.ctx, .unknown, typ, value);
        try self.function.getEntryBlock().addOperation(op.op);
        return op.getResult();
    }

    fn binary(self: *Witness, comptime add: bool, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        var op = if (add)
            try ArithDialect.AddOp.create(&self.ctx, .unknown, lhs, rhs)
        else
            try ArithDialect.SubOp.create(&self.ctx, .unknown, lhs, rhs);
        try self.function.getEntryBlock().addOperation(op.op);
        return op.getResult();
    }

    fn ret(self: *Witness, values: []const *ir.Value) !void {
        const op = try FuncDialect.ReturnOp.create(&self.ctx, .unknown, values);
        try self.function.getEntryBlock().addOperation(op.op);
    }

    fn run(self: *Witness, args: []const i64) !ExecuteResult {
        return compileAndRun(&self.backend, self.module, "witness", args);
    }
};

test "aarch64 native reordered operands preserve every argument register" {
    if (!supports_native_execution) return error.SkipZigTest;
    const args = [_]i64{ 3, 17, -9, 41, -23, 68, 107, -201 };
    for (0..max_arguments) |lhs| {
        for (0..max_arguments) |rhs| {
            var witness: Witness = undefined;
            try witness.init(.i64, max_arguments, 1);
            defer witness.deinit();
            const result = try witness.binary(false, witness.function.getArgument(lhs), witness.function.getArgument(rhs));
            try witness.ret(&.{result});
            try std.testing.expectEqual(args[lhs] - args[rhs], (try witness.run(&args)).asInt().?);
        }
    }
}

test "aarch64 native refuses an effect outside the return dependency tree by name" {
    if (!supports_native_execution) return error.SkipZigTest;
    var witness: Witness = undefined;
    try witness.init(.i64, 0, 1);
    defer witness.deinit();
    const number = try witness.constant(172);
    const effect = try FuncDialect.SyscallOp.create(&witness.ctx, .unknown, number, &.{}, number.type);
    try witness.function.getEntryBlock().addOperation(effect.op);
    try witness.ret(&.{try witness.constant(42)});
    try std.testing.expectError(BackendError.UnsupportedOperation, witness.run(&.{}));
    try std.testing.expectEqualStrings("func.syscall", witness.diagnostic_operation);
}

test "aarch64 native narrow signed and unsigned integers normalize at each definition" {
    if (!supports_native_execution) return error.SkipZigTest;
    const Case = struct { kind: dialects.arith.ScalarKind, maximum: i64, overflow: i64, underflow: i64 };
    const cases = [_]Case{
        .{ .kind = .i8, .maximum = 127, .overflow = -128, .underflow = -1 },
        .{ .kind = .i16, .maximum = 32767, .overflow = -32768, .underflow = -1 },
        .{ .kind = .i32, .maximum = 2147483647, .overflow = -2147483648, .underflow = -1 },
        .{ .kind = .i64, .maximum = std.math.maxInt(i64), .overflow = std.math.minInt(i64), .underflow = -1 },
        .{ .kind = .u8, .maximum = 255, .overflow = 0, .underflow = 255 },
        .{ .kind = .u16, .maximum = 65535, .overflow = 0, .underflow = 65535 },
        .{ .kind = .u32, .maximum = 4294967295, .overflow = 0, .underflow = 4294967295 },
        .{ .kind = .u64, .maximum = -1, .overflow = 0, .underflow = -1 },
        .{ .kind = .index, .maximum = -1, .overflow = 0, .underflow = -1 },
    };
    for (cases) |case| {
        inline for (.{ true, false }) |add| {
            var witness: Witness = undefined;
            try witness.init(case.kind, 2, 1);
            defer witness.deinit();
            const result = try witness.binary(add, witness.function.getArgument(0), witness.function.getArgument(1));
            try witness.ret(&.{result});
            const args = [_]i64{ if (add) case.maximum else 0, 1 };
            try std.testing.expectEqual(if (add) case.overflow else case.underflow, (try witness.run(&args)).asInt().?);
        }
        var identity: Witness = undefined;
        try identity.init(case.kind, 1, 1);
        defer identity.deinit();
        try identity.ret(&.{identity.function.getArgument(0)});
        try std.testing.expectEqual(case.underflow, (try identity.run(&.{-1})).asInt().?);
        var constant: Witness = undefined;
        try constant.init(case.kind, 0, 1);
        defer constant.deinit();
        try constant.ret(&.{try constant.constant(-1)});
        try std.testing.expectEqual(case.underflow, (try constant.run(&.{})).asInt().?);
    }
}

test "aarch64 native boolean arguments and constants and void results" {
    if (!supports_native_execution) return error.SkipZigTest;
    for ([_]bool{ false, true }) |value| {
        var identity: Witness = undefined;
        try identity.init(.bool, 1, 1);
        defer identity.deinit();
        try identity.ret(&.{identity.function.getArgument(0)});
        try std.testing.expectEqual(@as(i64, @intFromBool(value)), (try identity.run(&.{@intFromBool(value)})).asInt().?);
        var constant: Witness = undefined;
        try constant.init(.bool, 0, 1);
        defer constant.deinit();
        var op = try ArithDialect.ConstantOp.createBool(&constant.ctx, .unknown, value);
        try constant.function.getEntryBlock().addOperation(op.op);
        try constant.ret(&.{op.getResult()});
        try std.testing.expectEqual(@as(i64, @intFromBool(value)), (try constant.run(&.{})).asInt().?);
    }
    for ([_]usize{ 0, max_arguments }) |count| {
        var witness: Witness = undefined;
        try witness.init(.i64, count, 0);
        defer witness.deinit();
        try witness.ret(&.{});
        const args: [max_arguments]i64 = @splat(42);
        try std.testing.expectEqual(ExecuteResult.void_, try witness.run(args[0..count]));
    }
}

test "aarch64 native wrong arity is refused before code generation or entry" {
    if (!supports_native_execution) return error.SkipZigTest;
    var witness: Witness = undefined;
    try witness.init(.i64, 2, 1);
    defer witness.deinit();

    const effect = try FuncDialect.SyscallOp.create(&witness.ctx, .unknown, witness.function.getArgument(0), &.{}, witness.function.getArgument(0).type);
    try witness.function.getEntryBlock().addOperation(effect.op);
    try witness.ret(&.{witness.function.getArgument(1)});
    const args: [max_arguments + 1]i64 = @splat(172);
    for ([_]usize{ 0, 1, 3, max_arguments + 1 }) |count| {
        try std.testing.expectError(BackendError.ExecutionFailed, witness.run(args[0..count]));
        try std.testing.expectEqualStrings("func.func", witness.diagnostic_operation);
        try std.testing.expect(std.mem.indexOf(u8, witness.diagnostic_message, "argument count") != null);
    }
    try std.testing.expectError(BackendError.UnsupportedOperation, witness.run(args[0..2]));
    try std.testing.expectEqualStrings("func.syscall", witness.diagnostic_operation);
}

test "aarch64 native argument result and register pressure boundaries" {
    if (!supports_native_execution) return error.SkipZigTest;
    var arguments: Witness = undefined;
    try arguments.init(.i64, max_arguments + 1, 1);
    defer arguments.deinit();
    try arguments.ret(&.{arguments.function.getArgument(0)});
    const args: [max_arguments + 1]i64 = @splat(0);
    try std.testing.expectError(BackendError.UnsupportedOperation, arguments.run(&args));
    try std.testing.expect(std.mem.indexOf(u8, arguments.diagnostic_message, "8 arguments") != null);
    var results: Witness = undefined;
    try results.init(.i64, 1, max_results + 1);
    defer results.deinit();
    const arg = results.function.getArgument(0);
    try results.ret(&.{ arg, arg });
    try std.testing.expectError(BackendError.UnsupportedOperation, results.run(&.{0}));
    try std.testing.expect(std.mem.indexOf(u8, results.diagnostic_message, "1 result") != null);

    for ([_]usize{ placement.max_registers, placement.max_registers + 1 }) |count| {
        var pressure: Witness = undefined;
        try pressure.init(.i64, 0, 1);
        defer pressure.deinit();
        var values: [placement.max_registers + 1]*ir.Value = undefined;
        for (values[0..count], 0..) |*value, index| value.* = try pressure.constant(@intCast(index + 1));
        var sum = values[0];
        for (values[1..count]) |value| sum = try pressure.binary(true, sum, value);

        const doubled = try pressure.binary(true, sum, sum);
        const restored = try pressure.binary(false, doubled, sum);
        try pressure.ret(&.{restored});
        try std.testing.expectEqual(@as(i64, @intCast(count * (count + 1) / 2)), (try pressure.run(&.{})).asInt().?);
    }
}

/// Compare typed integer bits. Evaluator attributes may carry signed raw bits
/// for an unsigned operation, so the declared result type owns extension.
fn expectEvaluator(witness: *Witness, args: []const i64) !void {
    const Evaluator = @import("../../root.zig").eval.Evaluator;
    var evaluator = Evaluator.init(witness.arena.allocator(), &witness.ctx);
    defer evaluator.deinit();
    try evaluator.setRootOperation(witness.module);
    var attributes: [max_arguments]ir.Attribute = undefined;
    for (args, 0..) |arg, index| {
        const argument_kind = try scalarIntegerKind(witness.function.op, witness.function.getArgument(index).type);
        attributes[index] = if (argument_kind == .bool)
            try witness.ctx.getBoolAttr(arg != 0)
        else
            try witness.ctx.getI64Attr(canonicalInteger(arg, argument_kind));
    }
    const attribute = try evaluator.evaluateFunctionOp(witness.function.op, attributes[0..args.len]);
    const raw = if (attribute.cast(ir.Attribute.BoolAttr)) |boolean|
        @as(i64, @intFromBool(boolean.getValue()))
    else
        ArithDialect.getIntValue(attribute) orelse return error.EvalResultNotInteger;
    const kind = try scalarIntegerKind(witness.function.op, witness.function.getResultTypes()[0]);
    const descriptor = dialects.arith.scalarDescriptor(kind);
    const bits = descriptor.bit_width;
    const scalar = dialects.arith.scalar;
    const expected = if (descriptor.class == .signed_integer)
        scalar.truncate(raw, bits)
    else
        scalar.unsignedResult(@bitCast(raw), bits);
    try std.testing.expectEqual(expected, (try witness.run(args)).asInt().?);
}

test "aarch64 native frame slots and live values at capacity and one past" {
    if (!supports_native_execution) return error.SkipZigTest;
    const full = placement.max_live_values;
    for ([_]usize{ placement.max_registers, placement.max_registers + 1, full, full + 1 }) |count| {
        var witness: Witness = undefined;
        try witness.init(.i64, 0, 1);
        defer witness.deinit();
        var values: [full + 1]*ir.Value = undefined;
        for (values[0..count], 0..) |*value, index| value.* = try witness.constant(@intCast(index + 1));
        var sum = values[0];
        for (values[1..count]) |value| sum = try witness.binary(true, sum, value);
        try witness.ret(&.{sum});
        if (count <= full) {
            var plan: placement.Plan = .{};
            try plan.build(witness.function.getEntryBlock());
            try std.testing.expectEqual(count - placement.max_registers, plan.frame_slots);
            try std.testing.expectEqual(@as(usize, 0), plan.frameBytes() % 16);
            try expectEvaluator(&witness, &.{});
        } else {
            try std.testing.expectError(BackendError.UnsupportedOperation, witness.run(&.{}));
            try std.testing.expectEqualStrings("arith.constant", witness.diagnostic_operation);
            try std.testing.expect(std.mem.indexOf(u8, witness.diagnostic_message, "64 frame slots") != null);
        }
    }
}

test "aarch64 native tracked values at capacity and one past" {
    if (!supports_native_execution) return error.SkipZigTest;
    for ([_]usize{ placement.max_values, placement.max_values + 1 }) |count| {
        var witness: Witness = undefined;
        try witness.init(.i64, 1, 1);
        defer witness.deinit();
        var value = witness.function.getArgument(0);
        for (0..count) |_| value = try witness.binary(true, value, witness.function.getArgument(0));
        try witness.ret(&.{value});
        if (count == placement.max_values) {
            try expectEvaluator(&witness, &.{17});
        } else {
            try std.testing.expectError(BackendError.UnsupportedOperation, witness.run(&.{17}));
            try std.testing.expectEqualStrings("arith.add", witness.diagnostic_operation);
            try std.testing.expect(std.mem.indexOf(u8, witness.diagnostic_message, "256 tracked values") != null);
        }
    }
}

test "aarch64 placement operation bound at capacity and one past" {
    var witness: Witness = undefined;
    try witness.init(.i64, 0, 0);
    defer witness.deinit();
    for (0..placement.max_operations) |_| try witness.ret(&.{});
    var plan: placement.Plan = .{};
    try plan.build(witness.function.getEntryBlock());
    try witness.ret(&.{});
    try std.testing.expectError(error.OperationCapacity, plan.build(witness.function.getEntryBlock()));
}

test "aarch64 native expired spill slots are reused across pressure groups" {
    if (!supports_native_execution) return error.SkipZigTest;
    var witness: Witness = undefined;
    try witness.init(.i64, 0, 1);
    defer witness.deinit();
    const count = placement.max_registers + 3;
    var values: [count]*ir.Value = undefined;
    var result = try witness.constant(0);
    for (0..8) |group| {
        for (&values, 0..) |*value, index| value.* = try witness.constant(@intCast(group * count + index));
        for (values) |value| result = try witness.binary(true, result, value);
    }
    try witness.ret(&.{result});
    var plan: placement.Plan = .{};
    try plan.build(witness.function.getEntryBlock());
    try std.testing.expectEqual(@as(usize, 4), plan.frame_slots);
    try expectEvaluator(&witness, &.{});
}

test "aarch64 native admitted scalar operations match evaluator at extremes and seeded inputs" {
    if (!supports_native_execution) return error.SkipZigTest;
    const kinds = [_]dialects.arith.ScalarKind{ .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .index };
    var seed: u64 = 0x6f37_92ba_1d08_5ce4;
    for (kinds) |kind| {
        const width = dialects.arith.scalarBitWidth(kind);
        const sign_bit: u64 = @as(u64, 1) << @intCast(width - 1);
        const edges = [_]i64{ 0, 1, -1, @bitCast(sign_bit), @bitCast(sign_bit - 1) };
        for (0..edges.len + 8) |sample| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            const raw: i64 = if (sample < edges.len) edges[sample] else @bitCast(seed);
            const other: i64 = if (sample < edges.len) edges[edges.len - sample - 1] else @bitCast(seed ^ 0xa6ac_e510_d07b_5823);
            var constant: Witness = undefined;
            try constant.init(kind, 0, 1);
            defer constant.deinit();
            try constant.ret(&.{try constant.constant(raw)});
            try expectEvaluator(&constant, &.{});
            inline for (.{ true, false }) |add| {
                var witness: Witness = undefined;
                try witness.init(kind, 2, 1);
                defer witness.deinit();
                const result = try witness.binary(add, witness.function.getArgument(0), witness.function.getArgument(1));
                try witness.ret(&.{result});
                try expectEvaluator(&witness, &.{ raw, other });
            }
        }
    }
    for ([_]bool{ false, true }) |value| {
        var witness: Witness = undefined;
        try witness.init(.bool, 0, 1);
        defer witness.deinit();
        const constant = try ArithDialect.ConstantOp.createBool(&witness.ctx, .unknown, value);
        try witness.function.getEntryBlock().addOperation(constant.op);
        try witness.ret(&.{constant.getResult()});
        try expectEvaluator(&witness, &.{});
    }
}

const integer_kinds = [_]dialects.arith.ScalarKind{ .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .index };

fn canonicalInteger(raw: i64, kind: dialects.arith.ScalarKind) i64 {
    const scalar = dialects.arith.scalar;
    const descriptor = dialects.arith.scalarDescriptor(kind);
    return if (descriptor.class == .signed_integer)
        scalar.truncate(raw, descriptor.bit_width)
    else
        scalar.unsignedResult(@bitCast(raw), descriptor.bit_width);
}

fn nextSeed(seed: *u64) i64 {
    seed.* ^= seed.* << 13;
    seed.* ^= seed.* >> 7;
    seed.* ^= seed.* << 17;
    return @bitCast(seed.*);
}

fn integerSamples(kind: dialects.arith.ScalarKind, seed: *u64) [13]i64 {
    const width = dialects.arith.scalarBitWidth(kind);
    const sign_bit: u64 = @as(u64, 1) << @intCast(width - 1);
    var samples: [13]i64 = undefined;
    const edges = [_]i64{ 0, 1, -1, @bitCast(sign_bit), @bitCast(sign_bit - 1) };
    for (&samples, 0..) |*sample, index| {
        sample.* = canonicalInteger(if (index < edges.len) edges[index] else nextSeed(seed), kind);
    }
    return samples;
}

test "aarch64 native scalar binary and unary operations differentially cover every integer width" {
    if (!supports_native_execution) return error.SkipZigTest;
    var seed: u64 = 0xd761_2c93_a5e8_04bf;
    for (integer_kinds) |kind| {
        const samples = integerSamples(kind, &seed);
        inline for (.{ ArithDialect.MulOp, ArithDialect.DivOp, ArithDialect.RemOp, ArithDialect.AndOp, ArithDialect.OrOp, ArithDialect.XorOp, ArithDialect.MinOp, ArithDialect.MaxOp, ArithDialect.UmulhiOp, ArithDialect.ShlOp, ArithDialect.ShrOp, ArithDialect.UshrOp }) |Op| {
            var witness: Witness = undefined;
            try witness.init(kind, 2, 1);
            defer witness.deinit();
            const op = try Op.create(&witness.ctx, .unknown, witness.function.getArgument(0), witness.function.getArgument(1));
            try witness.function.getEntryBlock().addOperation(op.op);
            try witness.ret(&.{op.getResult()});
            for (samples, 0..) |lhs, index| {
                var rhs = samples[(index + 3) % samples.len];
                if (Op == ArithDialect.DivOp or Op == ArithDialect.RemOp) {
                    const bits = dialects.arith.scalarBitWidth(kind);
                    const minimum: i64 = @intCast(dialects.arith.scalar.intLimits(bits).min);
                    if (rhs == 0 or (lhs == minimum and rhs == -1)) rhs = 1;
                }
                if (Op == ArithDialect.ShlOp or Op == ArithDialect.ShrOp or Op == ArithDialect.UshrOp) {
                    rhs = @intCast(index % dialects.arith.scalarBitWidth(kind));
                    if (index == samples.len - 1) rhs = dialects.arith.scalarBitWidth(kind) - 1;
                }
                try expectEvaluator(&witness, &.{ lhs, rhs });
            }
        }
        inline for (.{ ArithDialect.NegOp, ArithDialect.NotOp, ArithDialect.AbsOp, ArithDialect.PopCountOp }) |Op| {
            var witness: Witness = undefined;
            try witness.init(kind, 1, 1);
            defer witness.deinit();
            const op = try Op.create(&witness.ctx, .unknown, witness.function.getArgument(0));
            try witness.function.getEntryBlock().addOperation(op.op);
            try witness.ret(&.{op.getResult()});
            for (samples) |value| {
                if (Op == ArithDialect.AbsOp and Emitter.unsignedKind(kind) and value < 0) {
                    try expectTypedAbsolute(&witness, &.{value}, value, kind);
                } else {
                    try expectEvaluator(&witness, &.{value});
                }
            }
        }
    }
}

test "aarch64 native all integer comparison predicates match evaluator" {
    if (!supports_native_execution) return error.SkipZigTest;
    var seed: u64 = 0xab16_c78f_2109_d4e3;
    for (integer_kinds) |kind| {
        const samples = integerSamples(kind, &seed);
        inline for (std.meta.tags(dialects.arith.CmpPredicate)) |predicate| {
            var witness: Witness = undefined;
            try witness.initSignature(kind, .bool, 2, 1);
            defer witness.deinit();
            const cmp = try ArithDialect.CmpOp.create(&witness.ctx, .unknown, predicate, witness.function.getArgument(0), witness.function.getArgument(1));
            try witness.function.getEntryBlock().addOperation(cmp.op);
            try witness.ret(&.{cmp.getResult()});
            for (samples, 0..) |value, index| {
                try expectEvaluator(&witness, &.{ value, samples[(index + 3) % samples.len] });
                try expectEvaluator(&witness, &.{ value, value });
            }
        }
    }
}

test "aarch64 native integer casts cover every source destination width pair" {
    if (!supports_native_execution) return error.SkipZigTest;
    var seed: u64 = 0x653e_920b_f8d4_107c;
    for (integer_kinds) |source| {
        const samples = integerSamples(source, &seed);
        for (integer_kinds) |destination| {
            var witness: Witness = undefined;
            try witness.initSignature(source, destination, 1, 1);
            defer witness.deinit();
            const cast = try ArithDialect.CastOp.create(&witness.ctx, .unknown, witness.function.getArgument(0), witness.function.getResultTypes()[0]);
            try witness.function.getEntryBlock().addOperation(cast.op);
            try witness.ret(&.{cast.getResult()});
            for (samples) |value| try expectEvaluator(&witness, &.{value});
        }
    }
}

test "aarch64 native select and boolean scalar operations match evaluator" {
    if (!supports_native_execution) return error.SkipZigTest;
    var seed: u64 = 0x8da2_6094_b713_f5ec;
    for (integer_kinds) |kind| {
        const samples = integerSamples(kind, &seed);
        var witness: Witness = undefined;
        try witness.init(kind, 2, 1);
        defer witness.deinit();
        const lhs = witness.function.getArgument(0);
        const rhs = witness.function.getArgument(1);
        const cmp = try ArithDialect.CmpOp.create(&witness.ctx, .unknown, .eq, lhs, rhs);
        try witness.function.getEntryBlock().addOperation(cmp.op);
        const select = try ArithDialect.SelectOp.create(&witness.ctx, .unknown, cmp.getResult(), lhs, rhs);
        try witness.function.getEntryBlock().addOperation(select.op);
        try witness.ret(&.{select.getResult()});
        for (samples, 0..) |value, index| {
            try expectEvaluator(&witness, &.{ value, samples[(index + 1) % samples.len] });
            try expectEvaluator(&witness, &.{ value, value });
        }
    }
    inline for (.{ ArithDialect.AndOp, ArithDialect.OrOp, ArithDialect.XorOp }) |Op| {
        var witness: Witness = undefined;
        try witness.init(.bool, 2, 1);
        defer witness.deinit();
        const op = try Op.create(&witness.ctx, .unknown, witness.function.getArgument(0), witness.function.getArgument(1));
        try witness.function.getEntryBlock().addOperation(op.op);
        try witness.ret(&.{op.getResult()});
        for (0..2) |a| for (0..2) |b| try expectEvaluator(&witness, &.{ @intCast(a), @intCast(b) });
    }
    var witness: Witness = undefined;
    try witness.init(.bool, 1, 1);
    defer witness.deinit();
    const op = try ArithDialect.NotOp.create(&witness.ctx, .unknown, witness.function.getArgument(0));
    try witness.function.getEntryBlock().addOperation(op.op);
    try witness.ret(&.{op.getResult()});
    try expectEvaluator(&witness, &.{0});
    try expectEvaluator(&witness, &.{1});
}

fn expectTrap(witness: *Witness, args: []const i64) !void {
    var evaluator = @import("../../root.zig").eval.Evaluator.init(witness.arena.allocator(), &witness.ctx);
    defer evaluator.deinit();
    try evaluator.setRootOperation(witness.module);
    var attributes: [max_arguments]ir.Attribute = undefined;
    for (args, 0..) |arg, index| attributes[index] = try witness.ctx.getI64Attr(arg);
    try std.testing.expectError(error.InvalidOperand, evaluator.evaluateFunctionOp(witness.function.op, attributes[0..args.len]));
    switch (try sys.process.fork()) {
        .child => {
            _ = witness.run(args) catch sys.process.exit(101);
            sys.process.exit(102);
        },
        .parent => |pid| {
            const termination = try sys.process.waitDirect(pid);
            switch (termination) {
                .signal => |signal| try std.testing.expect(signal == .TRAP),
                else => return error.ExpectedSigtrap,
            }
        },
    }
}

test "aarch64 native invalid arithmetic traps even when its result is unused" {
    if (!supports_native_execution) return error.SkipZigTest;
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    for (integer_kinds) |kind| {
        const bits = dialects.arith.scalarBitWidth(kind);
        inline for (.{ ArithDialect.DivOp, ArithDialect.RemOp, ArithDialect.ShlOp, ArithDialect.ShrOp, ArithDialect.UshrOp }) |Op| {
            var witness: Witness = undefined;
            try witness.init(kind, 2, 1);
            defer witness.deinit();
            const op = try Op.create(&witness.ctx, .unknown, witness.function.getArgument(0), witness.function.getArgument(1));
            try witness.function.getEntryBlock().addOperation(op.op);
            try witness.ret(&.{witness.function.getArgument(0)});
            if (Op == ArithDialect.DivOp or Op == ArithDialect.RemOp) {
                try expectTrap(&witness, &.{ 1, 0 });
                if (dialects.arith.scalarKindIsSignedInteger(kind) and kind != .index) {
                    const minimum: i64 = @intCast(dialects.arith.scalar.intLimits(bits).min);
                    try expectTrap(&witness, &.{ minimum, -1 });
                }
            } else {
                try expectTrap(&witness, &.{ 1, bits });
                try expectTrap(&witness, &.{ 1, -1 });
            }
        }
    }
}

test "aarch64 native statically certain arithmetic failures refuse by operation name" {
    if (!supports_native_execution) return error.SkipZigTest;
    inline for (.{ ArithDialect.DivOp, ArithDialect.RemOp, ArithDialect.ShlOp, ArithDialect.ShrOp, ArithDialect.UshrOp }) |Op| {
        var witness: Witness = undefined;
        try witness.init(.i64, 0, 1);
        defer witness.deinit();
        const lhs = try witness.constant(1);
        const rhs = try witness.constant(if (Op == ArithDialect.DivOp or Op == ArithDialect.RemOp) 0 else 64);
        const op = try Op.create(&witness.ctx, .unknown, lhs, rhs);
        try witness.function.getEntryBlock().addOperation(op.op);
        try witness.ret(&.{lhs});
        try std.testing.expectError(BackendError.UnsupportedOperation, witness.run(&.{}));
        try std.testing.expectEqualStrings(Op.operation_name, witness.diagnostic_operation);
    }
}

test "aarch64 native scalar temporaries preserve spilled operands and results" {
    if (!supports_native_execution) return error.SkipZigTest;
    inline for (.{ ArithDialect.MulOp, ArithDialect.DivOp, ArithDialect.RemOp, ArithDialect.AndOp, ArithDialect.OrOp, ArithDialect.XorOp, ArithDialect.MinOp, ArithDialect.MaxOp, ArithDialect.UmulhiOp, ArithDialect.ShlOp, ArithDialect.ShrOp, ArithDialect.UshrOp }) |Op| {
        var witness: Witness = undefined;
        try witness.init(.i64, 0, 1);
        defer witness.deinit();
        const count = placement.max_registers + 4;
        var values: [count]*ir.Value = undefined;
        for (&values, 0..) |*value, index| value.* = try witness.constant(@intCast(index + 1));
        const op = try Op.create(&witness.ctx, .unknown, values[count - 1], values[count - 2]);
        try witness.function.getEntryBlock().addOperation(op.op);
        var result = op.getResult();
        for (values) |value| result = try witness.binary(true, result, value);
        try witness.ret(&.{result});
        try expectEvaluator(&witness, &.{});
    }
    inline for (.{ ArithDialect.AbsOp, ArithDialect.NegOp, ArithDialect.NotOp, ArithDialect.PopCountOp }) |Op| {
        var witness: Witness = undefined;
        try witness.init(.i64, 0, 1);
        defer witness.deinit();
        const count = placement.max_registers + 4;
        var values: [count]*ir.Value = undefined;
        for (&values, 0..) |*value, index| value.* = try witness.constant(-@as(i64, @intCast(index + 1)));
        const op = try Op.create(&witness.ctx, .unknown, values[count - 1]);
        try witness.function.getEntryBlock().addOperation(op.op);
        var result = op.getResult();
        for (values) |value| result = try witness.binary(true, result, value);
        try witness.ret(&.{result});
        try expectEvaluator(&witness, &.{});
    }
}

test "aarch64 native literal signed division overflow refuses by name at every width" {
    if (!supports_native_execution) return error.SkipZigTest;
    for ([_]dialects.arith.ScalarKind{ .i8, .i16, .i32, .i64 }) |kind| {
        inline for (.{ ArithDialect.DivOp, ArithDialect.RemOp }) |Op| {
            var witness: Witness = undefined;
            try witness.init(kind, 0, 1);
            defer witness.deinit();
            const bits = dialects.arith.scalarBitWidth(kind);
            const lhs = try witness.constant(@intCast(dialects.arith.scalar.intLimits(bits).min));
            const rhs = try witness.constant(-1);
            const op = try Op.create(&witness.ctx, .unknown, lhs, rhs);
            try witness.function.getEntryBlock().addOperation(op.op);
            try witness.ret(&.{op.getResult()});
            try std.testing.expectError(BackendError.UnsupportedOperation, witness.run(&.{}));
            try std.testing.expectEqualStrings(Op.operation_name, witness.diagnostic_operation);
            try std.testing.expect(std.mem.indexOf(u8, witness.diagnostic_message, "SignedDivisionOverflow") != null);
        }
    }
}

/// The evaluator observes raw Attribute signs for abs, while the typed contract
/// treats unsigned abs as identity and signed abs as wrapping arithmetic.
fn expectTypedAbsolute(witness: *Witness, args: []const i64, raw: i64, kind: dialects.arith.ScalarKind) !void {
    const input = canonicalInteger(raw, kind);
    const expected = if (Emitter.unsignedKind(kind)) input else dialects.arith.scalar.absWrap(input, dialects.arith.scalarBitWidth(kind));
    try std.testing.expectEqual(expected, (try witness.run(args)).asInt().?);
}

test "aarch64 native composed absolute value follows normalized typed operands" {
    if (!supports_native_execution) return error.SkipZigTest;
    for (integer_kinds) |kind| {
        var witness: Witness = undefined;
        try witness.init(kind, 2, 1);
        defer witness.deinit();
        const difference = try witness.binary(false, witness.function.getArgument(0), witness.function.getArgument(1));
        const absolute = try ArithDialect.AbsOp.create(&witness.ctx, .unknown, difference);
        try witness.function.getEntryBlock().addOperation(absolute.op);
        try witness.ret(&.{absolute.getResult()});
        try expectTypedAbsolute(&witness, &.{ 0, 1 }, -1, kind);
        const minimum: i64 = @bitCast(@as(u64, 1) << @intCast(dialects.arith.scalarBitWidth(kind) - 1));
        try expectTypedAbsolute(&witness, &.{ minimum, 0 }, minimum, kind);
        var literal: Witness = undefined;
        try literal.init(kind, 0, 1);
        defer literal.deinit();
        const raw: i64 = if (Emitter.unsignedKind(kind)) -1 else @bitCast(@as(u64, std.math.maxInt(u64)) >> @intCast(64 - dialects.arith.scalarBitWidth(kind)));
        const input = try literal.constant(raw);
        const abs = try ArithDialect.AbsOp.create(&literal.ctx, .unknown, input);
        try literal.function.getEntryBlock().addOperation(abs.op);
        try literal.ret(&.{abs.getResult()});
        try expectTypedAbsolute(&literal, &.{}, raw, kind);
    }
}

test "aarch64 backend refuses overflow arithmetic by name" {
    const allocator = std.testing.allocator;
    const Arith = dialects.ArithDialect;
    inline for (.{ Arith.AddoOp, Arith.SuboOp, Arith.MuloOp }) |Op| {
        for ([_]bool{ false, true }) |used| {
            var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
            defer ctx.deinit(allocator);
            try dialects.registerAllDialects(&ctx);
            const integer = try Arith.getScalarType(&ctx, .i64);
            const module = try BuiltinDialect.ModuleOp.create(&ctx, .unknown);
            const function = try FuncDialect.FuncOp.create(&ctx, .unknown, "overflow", &.{ integer, integer }, &.{integer});
            try module.getBodyBlock().addOperation(function.op);
            const checked = try Op.create(&ctx, .unknown, function.getArgument(0), function.getArgument(1));
            try function.getEntryBlock().addOperation(checked.op);
            const value = if (used) checked.getResult() else function.getArgument(0);
            const ret = try FuncDialect.ReturnOp.create(&ctx, .unknown, &.{value});
            try function.getEntryBlock().addOperation(ret.op);
            var backend = try Backend.init(allocator, &ctx);
            defer backend.deinit();
            try std.testing.expectError(error.UnsupportedOperation, backend.compileFunctionToArtifact(module.op, "overflow"));
        }
    }
}

const ScfDialect = dialects.ScfDialect;

fn blockConstant(witness: *Witness, block: *ir.Block, kind: dialects.arith.ScalarKind, value: i64) !*ir.Value {
    const typ = try ArithDialect.getScalarType(&witness.ctx, kind);
    const op = if (kind == .bool)
        try ArithDialect.ConstantOp.createBool(&witness.ctx, .unknown, value != 0)
    else
        try ArithDialect.ConstantOp.createInt(&witness.ctx, .unknown, typ, value);
    try block.addOperation(op.op);
    return op.getResult();
}

fn blockBinary(witness: *Witness, block: *ir.Block, comptime Op: type, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
    const op = try Op.create(&witness.ctx, .unknown, lhs, rhs);
    try block.addOperation(op.op);
    return op.getResult();
}

fn blockYield(witness: *Witness, block: *ir.Block, values: []const *ir.Value) !void {
    const op = try ScfDialect.YieldOp.create(&witness.ctx, .unknown, values);
    try block.addOperation(op.op);
}

fn blockCondition(witness: *Witness, block: *ir.Block, cond: *ir.Value, values: []const *ir.Value) !void {
    const op = try ScfDialect.ConditionOp.create(&witness.ctx, .unknown, cond, values);
    try block.addOperation(op.op);
}

fn blockCompare(witness: *Witness, block: *ir.Block, predicate: dialects.arith.CmpPredicate, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
    const op = try ArithDialect.CmpOp.create(&witness.ctx, .unknown, predicate, lhs, rhs);
    try block.addOperation(op.op);
    return op.getResult();
}

test "aarch64 native control if selects both branches with scalar results" {
    if (!supports_native_execution) return error.SkipZigTest;
    for (integer_kinds ++ [_]dialects.arith.ScalarKind{.bool}) |kind| {
        var witness: Witness = undefined;
        try witness.initSignature(.bool, kind, 1, 1);
        defer witness.deinit();
        const typ = witness.function.getResultTypes()[0];
        const branch = try ScfDialect.IfOp.create(&witness.ctx, .unknown, witness.function.getArgument(0), &.{typ});
        try witness.function.getEntryBlock().addOperation(branch.op);
        const yes = try blockConstant(&witness, branch.getThenBlock(), kind, 1);
        const no = try blockConstant(&witness, branch.getElseBlock().?, kind, 0);
        try blockYield(&witness, branch.getThenBlock(), &.{yes});
        try blockYield(&witness, branch.getElseBlock().?, &.{no});
        try witness.ret(&.{branch.getResult(0).?});
        try expectEvaluator(&witness, &.{0});
        try expectEvaluator(&witness, &.{1});
    }
}

test "aarch64 native control if without results preserves conditional failures" {
    if (!supports_native_execution) return error.SkipZigTest;
    var witness: Witness = undefined;
    try witness.init(.i64, 2, 1);
    defer witness.deinit();
    const entry = witness.function.getEntryBlock();
    const zero = try witness.constant(0);
    const cond = try blockCompare(&witness, entry, .ne, witness.function.getArgument(0), zero);
    const branch = try ScfDialect.IfOp.createWithoutElse(&witness.ctx, .unknown, cond);
    try entry.addOperation(branch.op);
    _ = try blockBinary(&witness, branch.getThenBlock(), ArithDialect.DivOp, witness.function.getArgument(0), witness.function.getArgument(1));
    try blockYield(&witness, branch.getThenBlock(), &.{});
    try witness.ret(&.{zero});
    try expectEvaluator(&witness, &.{ 0, 0 });
    try expectEvaluator(&witness, &.{ 1, 2 });
    if (@import("builtin").os.tag == .linux) try expectTrap(&witness, &.{ 1, 0 });
}

/// A before-region condition forwards a transformed value on both exit edges.
fn makeWhile(witness: *Witness, parent: *ir.Block, initial: *ir.Value, upper: *ir.Value, step: *ir.Value) !ScfDialect.WhileOp {
    const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{initial}, &.{initial.type});
    try parent.addOperation(loop.op);
    const before = loop.getBeforeBlock();
    const current = before.arguments.items[0];
    const cond = try blockCompare(witness, before, .slt, current, upper);
    try blockCondition(witness, before, cond, &.{current});
    const after = loop.getAfterBlock();
    const next = try blockBinary(witness, after, ArithDialect.AddOp, after.arguments.items[0], step);
    try blockYield(witness, after, &.{next});
    return loop;
}

test "aarch64 native control while zero one many tests and nested loops match evaluator" {
    if (!supports_native_execution) return error.SkipZigTest;
    for ([_]bool{ true, false }) |nested| {
        var witness: Witness = undefined;
        try witness.init(.i64, 2, 1);
        defer witness.deinit();
        const entry = witness.function.getEntryBlock();
        const one = try witness.constant(1);
        const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{witness.function.getArgument(0)}, witness.function.getResultTypes());
        try entry.addOperation(loop.op);
        const before = loop.getBeforeBlock();
        const current = before.arguments.items[0];
        const cond = try blockCompare(&witness, before, .slt, current, witness.function.getArgument(1));
        try blockCondition(&witness, before, cond, &.{current});
        const after = loop.getAfterBlock();
        const next = try blockBinary(&witness, after, ArithDialect.AddOp, after.arguments.items[0], one);
        const yielded = if (nested) value: {
            const inner = try makeWhile(&witness, after, after.arguments.items[0], next, one);
            break :value inner.op.getResult(0).?;
        } else next;
        try blockYield(&witness, after, &.{yielded});
        try witness.ret(&.{loop.op.getResult(0).?});
        for ([_]i64{ 0, 1, 19 }) |upper| try std.testing.expectEqual(upper, (try witness.run(&.{ 0, upper })).asInt().?);
        try std.testing.expectEqual(@as(i64, 8), (try witness.run(&.{ 8, 3 })).asInt().?);
        for ([_]i64{ 0, 1, 19 }) |upper| try expectEvaluator(&witness, &.{ 0, upper });
        try expectEvaluator(&witness, &.{ 8, 3 });
    }
}

test "aarch64 native control condition forwards computed exit and entry values" {
    if (!supports_native_execution) return error.SkipZigTest;
    var witness: Witness = undefined;
    try witness.init(.i64, 1, 1);
    defer witness.deinit();
    const one = try witness.constant(1);
    const ten = try witness.constant(10);
    const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{witness.function.getArgument(0)}, &.{one.type});
    try witness.function.getEntryBlock().addOperation(loop.op);
    const before = loop.getBeforeBlock();
    const next = try blockBinary(&witness, before, ArithDialect.AddOp, before.arguments.items[0], one);
    const cond = try blockCompare(&witness, before, .slt, next, ten);
    try blockCondition(&witness, before, cond, &.{next});
    try blockYield(&witness, loop.getAfterBlock(), loop.getAfterBlock().arguments.items);
    try witness.ret(&.{loop.op.getResult(0).?});
    for ([_]i64{ 0, 8, 9, 12 }) |initial| try expectEvaluator(&witness, &.{initial});
}

fn makeCounted(witness: *Witness, parent: *ir.Block, upper: *ir.Value, count: usize) !ScfDialect.ForOp {
    const zero = try blockConstant(witness, parent, .index, 0);
    const one = try blockConstant(witness, parent, .index, 1);
    var values: [control.max_carried_values + 1]*ir.Value = undefined;
    var types: [control.max_carried_values + 1]ir.Type = undefined;
    for (values[0..count], types[0..count], 0..) |*value, *typ, index| {
        value.* = try blockConstant(witness, parent, .index, @intCast(index));
        typ.* = zero.type;
    }
    const loop = try ScfDialect.ForOp.create(&witness.ctx, .unknown, zero, upper, one, values[0..count], types[0..count]);
    try parent.addOperation(loop.op);
    const body = loop.getBodyBlock();
    for (values[0..count], 0..) |*value, index| value.* = try blockBinary(witness, body, ArithDialect.AddOp, body.arguments.items[index + 1], body.arguments.items[0]);
    try blockYield(witness, body, values[0..count]);
    return loop;
}

test "aarch64 native control counted loop zero one many iterations match evaluator" {
    if (!supports_native_execution) return error.SkipZigTest;
    var witness: Witness = undefined;
    try witness.init(.index, 1, 1);
    defer witness.deinit();
    const loop = try makeCounted(&witness, witness.function.getEntryBlock(), witness.function.getArgument(0), 1);
    try witness.ret(&.{loop.op.getResult(0).?});
    for ([_]i64{ 0, 1, 17 }) |upper| try std.testing.expectEqual(@divTrunc(upper * (upper - 1), 2), (try witness.run(&.{upper})).asInt().?);
    for ([_]i64{ 0, 1, 17 }) |upper| try expectEvaluator(&witness, &.{upper});
}

fn makeRotatingWhile(witness: *Witness, count: usize) !ScfDialect.WhileOp {
    const entry = witness.function.getEntryBlock();
    var values: [control.max_carried_values + 1]*ir.Value = undefined;
    var types: [control.max_carried_values + 1]ir.Type = undefined;
    for (values[0..count], types[0..count], 0..) |*value, *typ, index| {
        value.* = try witness.constant(@intCast(index));
        typ.* = value.*.type;
    }
    const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, values[0..count], types[0..count]);
    try entry.addOperation(loop.op);
    const before = loop.getBeforeBlock();
    const cond = try blockCompare(witness, before, .slt, before.arguments.items[0], witness.function.getArgument(0));
    values[0] = before.arguments.items[0];
    for (1..count) |index| values[index] = before.arguments.items[1 + index % (count - 1)];
    try blockCondition(witness, before, cond, values[0..count]);
    const after = loop.getAfterBlock();
    const one = try blockConstant(witness, after, .i64, 1);
    values[0] = try blockBinary(witness, after, ArithDialect.AddOp, after.arguments.items[0], one);
    for (1..count) |index| values[index] = after.arguments.items[1 + index % (count - 1)];
    try blockYield(witness, after, values[0..count]);
    return loop;
}

test "aarch64 native control carried bound parallel cycles and one past" {
    if (!supports_native_execution) return error.SkipZigTest;
    for ([_]usize{ control.max_carried_values + 1, control.max_carried_values }) |count| {
        var witness: Witness = undefined;
        try witness.init(.i64, 1, 1);
        defer witness.deinit();
        const loop = try makeRotatingWhile(&witness, count);
        var result = loop.op.getResult(0).?;
        for (1..count) |index| {
            const weight = try witness.constant(@intCast(index + 1));
            const product = try blockBinary(&witness, witness.function.getEntryBlock(), ArithDialect.MulOp, loop.op.getResult(index).?, weight);
            result = try witness.binary(true, result, product);
        }
        try witness.ret(&.{result});
        if (count > control.max_carried_values) {
            try std.testing.expectError(BackendError.UnsupportedOperation, witness.run(&.{0}));
            try std.testing.expectEqualStrings("scf.while", witness.diagnostic_operation);
            try std.testing.expect(std.mem.indexOf(u8, witness.diagnostic_message, "16 carried") != null);
        } else {
            for ([_]i64{ 0, 1, 13 }) |upper| {
                var expected = upper;
                for (1..count) |index| {
                    const rotated = 1 + (index - 1 + 2 * @as(usize, @intCast(upper)) + 1) % (count - 1);
                    expected += @intCast((index + 1) * rotated);
                }
                try std.testing.expectEqual(expected, (try witness.run(&.{upper})).asInt().?);
            }
            for ([_]i64{ 0, 1, 13 }) |upper| try expectEvaluator(&witness, &.{upper});
        }
    }
}

test "aarch64 native control pressure across back edges reaches frame bound and refuses one past" {
    if (!supports_native_execution) return error.SkipZigTest;
    const full = placement.max_live_values - 4;
    for ([_]usize{ full + 1, full, placement.max_registers + 2 }) |count| {
        var witness: Witness = undefined;
        try witness.init(.i64, 2, 1);
        defer witness.deinit();
        var captured: [full + 1]*ir.Value = undefined;
        for (captured[0..count], 0..) |*value, index| value.* = try witness.constant(@intCast(index + 1));
        const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{witness.function.getArgument(0)}, witness.function.getResultTypes());
        try witness.function.getEntryBlock().addOperation(loop.op);
        const before = loop.getBeforeBlock();
        const cond = try blockCompare(&witness, before, .slt, before.arguments.items[0], witness.function.getArgument(1));
        try blockCondition(&witness, before, cond, before.arguments.items);
        const after = loop.getAfterBlock();
        var sum = after.arguments.items[0];
        for (captured[0..count]) |value| sum = try blockBinary(&witness, after, ArithDialect.AddOp, sum, value);
        try blockYield(&witness, after, &.{sum});
        try witness.ret(&.{loop.op.getResult(0).?});
        var plan: placement.Plan = .{};
        if (count > full) {
            try std.testing.expectError(error.FrameCapacity, plan.build(witness.function.getEntryBlock()));
            try std.testing.expectError(BackendError.UnsupportedOperation, witness.run(&.{ 0, 10000 }));
        } else {
            try plan.build(witness.function.getEntryBlock());
            if (count == full) try std.testing.expectEqual(placement.max_frame_slots, plan.frame_slots);
            try std.testing.expect(plan.frameBytes() <= placement.max_frame_slots * placement.slot_bytes);
            for (captured[0..count]) |value| {
                for (plan.entries[0..plan.count]) |entry| {
                    if (entry.value == value) try std.testing.expectEqual(plan.loops[0].trailing, entry.range.end);
                }
            }
            for ([_]i64{ 0, 1, 10000 }) |upper| {
                const increment: i64 = @intCast(count * (count + 1) / 2);
                const expected = @divTrunc(upper + increment - 1, increment) * increment;
                try std.testing.expectEqual(expected, (try witness.run(&.{ 0, upper })).asInt().?);
            }
            for ([_]i64{ 0, 1, 10000 }) |upper| try expectEvaluator(&witness, &.{ 0, upper });
        }
    }
}

test "aarch64 native control traps only in the iteration reaching an invalid domain" {
    if (!supports_native_execution) return error.SkipZigTest;
    var witness: Witness = undefined;
    try witness.init(.i64, 1, 1);
    defer witness.deinit();
    const zero = try witness.constant(0);
    const one = try witness.constant(1);
    const three = try witness.constant(3);
    const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{zero}, &.{zero.type});
    try witness.function.getEntryBlock().addOperation(loop.op);
    const before = loop.getBeforeBlock();
    const cond = try blockCompare(&witness, before, .slt, before.arguments.items[0], witness.function.getArgument(0));
    try blockCondition(&witness, before, cond, before.arguments.items);
    const after = loop.getAfterBlock();
    const denominator = try blockBinary(&witness, after, ArithDialect.SubOp, three, after.arguments.items[0]);
    _ = try blockBinary(&witness, after, ArithDialect.DivOp, one, denominator);
    const next = try blockBinary(&witness, after, ArithDialect.AddOp, after.arguments.items[0], one);
    try blockYield(&witness, after, &.{next});
    try witness.ret(&.{loop.op.getResult(0).?});
    for ([_]i64{ 0, 1, 3 }) |upper| try expectEvaluator(&witness, &.{upper});
    if (@import("builtin").os.tag == .linux) try expectTrap(&witness, &.{4});
}

test "aarch64 native control nesting depth at limit and one past" {
    if (!supports_native_execution) return error.SkipZigTest;
    for ([_]usize{ control.max_depth, control.max_depth + 1 }) |depth| {
        var witness: Witness = undefined;
        try witness.initSignature(.bool, .i64, 1, 1);
        defer witness.deinit();
        var blocks: [control.max_depth + 1]*ir.Block = undefined;
        var block = witness.function.getEntryBlock();
        for (blocks[0..depth]) |*nested| {
            const branch = try ScfDialect.IfOp.createWithoutElse(&witness.ctx, .unknown, witness.function.getArgument(0));
            try block.addOperation(branch.op);
            block = branch.getThenBlock();
            nested.* = block;
        }
        for (blocks[0..depth]) |nested| try blockYield(&witness, nested, &.{});
        try witness.ret(&.{try witness.constant(42)});
        if (depth > control.max_depth) {
            try std.testing.expectError(BackendError.UnsupportedOperation, witness.run(&.{1}));
            try std.testing.expectEqualStrings("scf.if", witness.diagnostic_operation);
            try std.testing.expect(std.mem.indexOf(u8, witness.diagnostic_message, "32 nested") != null);
        } else {
            try expectEvaluator(&witness, &.{0});
            try expectEvaluator(&witness, &.{1});
        }
    }
}

test "aarch64 control branch displacement at signed encoding limits and one past" {
    var witness: Witness = undefined;
    try witness.init(.i64, 0, 1);
    defer witness.deinit();
    var emitter = Emitter.init(witness.arena.allocator());
    defer emitter.deinit();
    _ = try emitter.branch();
    const conditional_limit = @as(usize, std.math.maxInt(i19)) * Instruction.size;
    const branch_limit = @as(usize, std.math.maxInt(i26)) * Instruction.size;
    try emitter.patchBranch(witness.function.op, 0, conditional_limit, .eq);
    try std.testing.expectError(BackendError.UnsupportedOperation, emitter.patchBranch(witness.function.op, 0, conditional_limit + Instruction.size, .eq));
    try emitter.patchBranch(witness.function.op, 0, branch_limit, null);
    try std.testing.expectError(BackendError.UnsupportedOperation, emitter.patchBranch(witness.function.op, 0, branch_limit + Instruction.size, null));
}

test "aarch64 native control while admits every scalar carried type" {
    if (!supports_native_execution) return error.SkipZigTest;
    for (integer_kinds ++ [_]dialects.arith.ScalarKind{.bool}) |kind| {
        var witness: Witness = undefined;
        try witness.init(kind, 1, 1);
        defer witness.deinit();
        const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{witness.function.getArgument(0)}, witness.function.getResultTypes());
        try witness.function.getEntryBlock().addOperation(loop.op);
        const before = loop.getBeforeBlock();
        const cond = try blockConstant(&witness, before, .bool, 0);
        try blockCondition(&witness, before, cond, before.arguments.items);
        try blockYield(&witness, loop.getAfterBlock(), loop.getAfterBlock().arguments.items);
        try witness.ret(&.{loop.op.getResult(0).?});
        for ([_]i64{ 0, 1, -1 }) |value| try expectEvaluator(&witness, &.{value});
    }
}

test "aarch64 native control zero carried loops and resultless else regions" {
    if (!supports_native_execution) return error.SkipZigTest;
    var witness: Witness = undefined;
    try witness.initSignature(.bool, .i64, 1, 1);
    defer witness.deinit();
    const branch = try ScfDialect.IfOp.create(&witness.ctx, .unknown, witness.function.getArgument(0), &.{});
    try witness.function.getEntryBlock().addOperation(branch.op);
    try blockYield(&witness, branch.getThenBlock(), &.{});
    try blockYield(&witness, branch.getElseBlock().?, &.{});
    const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{}, &.{});
    try witness.function.getEntryBlock().addOperation(loop.op);
    const cond = try blockConstant(&witness, loop.getBeforeBlock(), .bool, 0);
    try blockCondition(&witness, loop.getBeforeBlock(), cond, &.{});
    try blockYield(&witness, loop.getAfterBlock(), &.{});
    try witness.ret(&.{try witness.constant(7)});
    try expectEvaluator(&witness, &.{0});
    try expectEvaluator(&witness, &.{1});
}

test "aarch64 control if and for carried limits accept full and refuse one past" {
    for ([_]usize{ control.max_carried_values, control.max_carried_values + 1 }) |count| {
        for ([_]bool{ false, true }) |counted| {
            var witness: Witness = undefined;
            try witness.init(.index, 0, 1);
            defer witness.deinit();
            const entry = witness.function.getEntryBlock();
            var op: *ir.Operation = undefined;
            if (counted) {
                const upper = try witness.constant(3);
                op = (try makeCounted(&witness, entry, upper, count)).op;
            } else {
                const cond = try blockConstant(&witness, entry, .bool, 1);
                var types: [control.max_carried_values + 1]ir.Type = @splat(witness.function.getResultTypes()[0]);
                const branch = try ScfDialect.IfOp.create(&witness.ctx, .unknown, cond, types[0..count]);
                try entry.addOperation(branch.op);
                for ([_]*ir.Block{ branch.getThenBlock(), branch.getElseBlock().? }, 0..) |block, alternative| {
                    var values: [control.max_carried_values + 1]*ir.Value = undefined;
                    for (values[0..count], 0..) |*value, index| value.* = try blockConstant(&witness, block, .index, @intCast(index + alternative));
                    try blockYield(&witness, block, values[0..count]);
                }
                op = branch.op;
            }
            var sum = op.getResult(0).?;
            for (1..count) |index| sum = try witness.binary(true, sum, op.getResult(index).?);
            try witness.ret(&.{sum});
            if (count > control.max_carried_values) {
                try std.testing.expectError(BackendError.UnsupportedOperation, witness.backend.compileFunctionToMachineCode(witness.module, "witness"));
                try std.testing.expectEqualStrings(if (counted) "scf.for" else "scf.if", witness.diagnostic_operation);
            } else {
                const bytes = try witness.backend.compileFunctionToMachineCode(witness.module, "witness");
                witness.arena.allocator().free(bytes);
                if (supports_native_execution) try expectEvaluator(&witness, &.{});
            }
        }
    }
}

test "aarch64 control rejects floating carried values and mismatched condition edges by name" {
    for ([_]bool{ false, true }) |floating| {
        var witness: Witness = undefined;
        try witness.init(.i64, 0, 1);
        defer witness.deinit();
        const initial = if (floating) value: {
            const typ = try ArithDialect.getScalarType(&witness.ctx, .f64);
            const constant = try ArithDialect.ConstantOp.createFloat(&witness.ctx, .unknown, typ, 1.0);
            try witness.function.getEntryBlock().addOperation(constant.op);
            break :value constant.getResult();
        } else try witness.constant(1);
        const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{initial}, &.{initial.type});
        try witness.function.getEntryBlock().addOperation(loop.op);
        const cond = try blockConstant(&witness, loop.getBeforeBlock(), .bool, 0);
        try blockCondition(&witness, loop.getBeforeBlock(), cond, &.{if (floating) loop.getBeforeBlock().arguments.items[0] else cond});
        try blockYield(&witness, loop.getAfterBlock(), loop.getAfterBlock().arguments.items);
        try witness.ret(&.{try witness.constant(0)});
        try std.testing.expectError(BackendError.UnsupportedOperation, witness.backend.compileFunctionToMachineCode(witness.module, "witness"));
        try std.testing.expectEqualStrings("scf.while", witness.diagnostic_operation);
    }
}

test "aarch64 native control for parallel carried rotations and nested counted loops" {
    if (!supports_native_execution) return error.SkipZigTest;
    for ([_]bool{ true, false }) |nested| {
        var witness: Witness = undefined;
        try witness.init(.index, 1, 1);
        defer witness.deinit();
        const entry = witness.function.getEntryBlock();
        const zero = try witness.constant(0);
        const one = try witness.constant(1);
        const count = control.max_carried_values;
        var initial: [count]*ir.Value = undefined;
        var types: [count]ir.Type = @splat(zero.type);
        for (&initial, 0..) |*value, index| value.* = try witness.constant(@intCast(index + 1));
        const loop = try ScfDialect.ForOp.create(&witness.ctx, .unknown, zero, witness.function.getArgument(0), one, &initial, &types);
        try entry.addOperation(loop.op);
        const body = loop.getBodyBlock();
        var yielded: [count]*ir.Value = undefined;
        for (&yielded, 0..) |*value, index| value.* = body.arguments.items[1 + (index + 1) % count];
        if (nested) {
            const inner = try makeCounted(&witness, body, body.arguments.items[0], 1);
            yielded[0] = try blockBinary(&witness, body, ArithDialect.AddOp, yielded[0], inner.op.getResult(0).?);
        }
        try blockYield(&witness, body, &yielded);
        var sum = loop.op.getResult(0).?;
        for (1..count) |index| {
            const weight = try witness.constant(@intCast(index + 1));
            const product = try blockBinary(&witness, entry, ArithDialect.MulOp, loop.op.getResult(index).?, weight);
            sum = try witness.binary(true, sum, product);
        }
        try witness.ret(&.{sum});
        for ([_]i64{ 0, 1, 7 }) |upper| {
            var expected_values: [count]i64 = undefined;
            for (&expected_values, 0..) |*value, index| value.* = @intCast(index + 1);
            for (0..@intCast(upper)) |iteration| {
                const saved = expected_values[0];
                for (0..count - 1) |index| expected_values[index] = expected_values[index + 1];
                expected_values[count - 1] = saved;
                if (nested and iteration > 0) expected_values[0] += @intCast(iteration * (iteration - 1) / 2);
            }
            var expected: i64 = 0;
            for (expected_values, 0..) |value, index| expected += value * @as(i64, @intCast(index + 1));
            try std.testing.expectEqual(expected, (try witness.run(&.{upper})).asInt().?);
        }
        for ([_]i64{ 0, 1, 7 }) |upper| try expectEvaluator(&witness, &.{upper});
    }
}

test "aarch64 native control while with constant bounds matches evaluator" {
    if (!supports_native_execution) return error.SkipZigTest;
    for ([_]i64{ 0, 1, 19 }) |upper_value| {
        var witness: Witness = undefined;
        try witness.init(.i64, 0, 1);
        defer witness.deinit();
        const zero = try witness.constant(0);
        const one = try witness.constant(1);
        const upper = try witness.constant(upper_value);
        const loop = try makeWhile(&witness, witness.function.getEntryBlock(), zero, upper, one);
        try witness.ret(&.{loop.op.getResult(0).?});
        try expectEvaluator(&witness, &.{});
    }
}

test "aarch64 native control constant bounded loop reaches its trap only on iteration four" {
    if (!supports_native_execution) return error.SkipZigTest;
    for ([_]i64{ 0, 1, 3, 4 }) |upper_value| {
        var witness: Witness = undefined;
        try witness.init(.i64, 0, 1);
        defer witness.deinit();
        const zero = try witness.constant(0);
        const one = try witness.constant(1);
        const three = try witness.constant(3);
        const upper = try witness.constant(upper_value);
        const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{zero}, &.{zero.type});
        try witness.function.getEntryBlock().addOperation(loop.op);
        const before = loop.getBeforeBlock();
        const cond = try blockCompare(&witness, before, .slt, before.arguments.items[0], upper);
        try blockCondition(&witness, before, cond, before.arguments.items);
        const after = loop.getAfterBlock();
        const denominator = try blockBinary(&witness, after, ArithDialect.SubOp, three, after.arguments.items[0]);
        _ = try blockBinary(&witness, after, ArithDialect.DivOp, one, denominator);
        const next = try blockBinary(&witness, after, ArithDialect.AddOp, after.arguments.items[0], one);
        try blockYield(&witness, after, &.{next});
        try witness.ret(&.{loop.op.getResult(0).?});
        if (upper_value < 4) {
            try expectEvaluator(&witness, &.{});
        } else if (@import("builtin").os.tag == .linux) {
            try expectTrap(&witness, &.{});
        }
    }
}

test "aarch64 native control counted induction bounds step and empty yield match evaluator" {
    if (!supports_native_execution) return error.SkipZigTest;
    const Case = struct { lower: i64, upper: i64, step: i64, carried: bool };
    for ([_]Case{
        .{ .lower = -3, .upper = 4, .step = 2, .carried = true },
        .{ .lower = 5, .upper = 5, .step = 1, .carried = true },
        .{ .lower = 5, .upper = 3, .step = 1, .carried = true },
        .{ .lower = 0, .upper = 7, .step = 2, .carried = false },
    }) |case| {
        var witness: Witness = undefined;
        try witness.init(.index, 0, 1);
        defer witness.deinit();
        const lower = try witness.constant(case.lower);
        const upper = try witness.constant(case.upper);
        const step = try witness.constant(case.step);
        const initial = try witness.constant(7);
        const loop = try ScfDialect.ForOp.create(&witness.ctx, .unknown, lower, upper, step, if (case.carried) &.{initial} else &.{}, if (case.carried) &.{initial.type} else &.{});
        try witness.function.getEntryBlock().addOperation(loop.op);
        const body = loop.getBodyBlock();
        if (case.carried) {
            const sum = try blockBinary(&witness, body, ArithDialect.AddOp, body.arguments.items[1], body.arguments.items[0]);
            try blockYield(&witness, body, &.{sum});
        } else try blockYield(&witness, body, &.{});
        try witness.ret(&.{if (case.carried) loop.op.getResult(0).? else initial});
        try expectEvaluator(&witness, &.{});
    }
}
