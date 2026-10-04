//! Reachable ordinary functions in callee-first order for GPU stage backends.
//!
//! Every stage backend plans its module here before it checks anything of its own, so a module
//! all of them refuse is refused here by one name. A stage body, and every helper a stage reaches,
//! holds only the memory `gpu.stage.admitsMemory` admits. A helper only kernels reach keeps the
//! kernel vocabulary.

const std = @import("std");
const choir = @import("../../root.zig");
const gpu = @import("../../dialects/gpu/root.zig");

const ir = choir.ir;
const FuncDialect = choir.dialects.FuncDialect;
const MemrefDialect = choir.dialects.MemrefDialect;

const Mark = u8;
const visiting: Mark = std.math.maxInt(Mark);
const max_call_depth = 64;
pub const SignatureError = error{UnsupportedHelperSignature};
pub const DepthError = error{CallChainTooDeep};
const PlanError = error{ OutOfMemory, UnsupportedOperation } || gpu.stage.MemoryError || SignatureError || DepthError;

pub const Plan = struct {
    allocator: std.mem.Allocator,
    functions: std.StringHashMapUnmanaged(*ir.Operation) = .{},
    marks: std.AutoHashMapUnmanaged(*ir.Operation, Mark) = .{},
    helpers: std.ArrayListUnmanaged(*ir.Operation) = .empty,
    /// Receives the refused memory operation or helper name.
    refused: ?*[]const u8 = null,

    /// Plans the stages first, so a helper both stages and kernels reach meets the stage rules.
    pub fn init(allocator: std.mem.Allocator, module: *ir.Operation, refused: ?*[]const u8) PlanError!Plan {
        var plan = Plan{ .allocator = allocator, .refused = refused };
        errdefer plan.deinit();
        const region = module.getRegion(0) orelse return error.UnsupportedOperation;
        const body = region.getEntryBlock() orelse return error.UnsupportedOperation;
        var ops = body.getOperations();
        while (ops.next()) |op| {
            if (!std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) continue;
            const name = (FuncDialect.FuncOp{ .op = op }).getName() orelse return error.UnsupportedOperation;
            const entry = try plan.functions.getOrPut(allocator, name);
            if (entry.found_existing) return error.UnsupportedOperation;
            entry.value_ptr.* = op;
        }
        for ([_]bool{ true, false }) |stage| {
            ops = body.getOperations();
            while (ops.next()) |op| {
                if (!std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) continue;
                const entry = if (stage) gpu.stage.stageOf(op) != null else op.getAttr("kernel") != null;
                if (!entry) continue;
                _ = try plan.walkCalls((FuncDialect.FuncOp{ .op = op }).getEntryBlock(), 0, stage);
            }
        }
        return plan;
    }

    pub fn deinit(self: *Plan) void {
        self.functions.deinit(self.allocator);
        self.marks.deinit(self.allocator);
        self.helpers.deinit(self.allocator);
    }

    pub fn function(self: *const Plan, name: []const u8) ?*ir.Operation {
        return self.functions.get(name);
    }

    /// A call made directly by a stage entry has depth zero. A completed mark
    /// holds the helper's tallest remaining call depth, with 255 reserved for
    /// the active DFS mark. No accepted helper height exceeds 63.
    fn visitHelper(self: *Plan, func: *ir.Operation, depth: usize, stage: bool) PlanError!Mark {
        try self.checkDepth(func, depth, 0);
        if (self.marks.get(func)) |mark| {
            if (mark == visiting) return error.UnsupportedOperation;
            try self.checkDepth(func, depth, mark);
            return mark;
        }
        if (func.getAttr("kernel") != null or gpu.stage.stageOf(func) != null) return error.UnsupportedOperation;
        if (stage and !admittedSignature(FuncDialect.FuncOp{ .op = func })) {
            if (self.refused) |name| name.* = (FuncDialect.FuncOp{ .op = func }).getName() orelse "";
            return error.UnsupportedHelperSignature;
        }
        const region = func.getRegion(0) orelse return error.UnsupportedOperation;
        if (!region.hasOneBlock()) return error.UnsupportedOperation;
        try validateHelperBlock(region.getEntryBlock().?);
        try self.marks.put(self.allocator, func, visiting);
        const height = try self.walkCalls(region.getEntryBlock().?, depth + 1, stage);
        try self.checkDepth(func, depth, height);
        std.debug.assert(height < max_call_depth);
        try self.marks.put(self.allocator, func, height);
        try self.helpers.append(self.allocator, func);
        return height;
    }

    fn checkDepth(self: *Plan, func: *ir.Operation, depth: usize, height: usize) PlanError!void {
        if (depth + height < max_call_depth) return;
        if (self.refused) |name| name.* = (FuncDialect.FuncOp{ .op = func }).getName() orelse "";
        return error.CallChainTooDeep;
    }

    fn admittedSignature(func: FuncDialect.FuncOp) bool {
        const results = func.getResultTypes();
        if (results.len > 1) return false;
        if (results.len == 1 and !admittedScalar(results[0])) return false;
        for (func.getArguments()) |arg| {
            if (!admittedScalar(arg.type) and !admittedLocalMemref(arg.type)) return false;
        }
        return true;
    }

    fn admittedLocalMemref(typ: ir.Type) bool {
        const params = MemrefDialect.parseMemrefParams(typ.getDialectParamKey() orelse return false) orelse return false;
        if (!std.mem.eql(u8, typ.getDialectTypeName() orelse return false, MemrefDialect.name)) return false;
        if (params.addr_space != .local) return false;
        const size = params.size orelse return false;
        if (size == 0 or size > std.math.maxInt(u32)) return false;
        const kind = choir.dialects.arith.scalarKindFromTypeName(params.element_type_name) orelse return false;
        return switch (kind) {
            .bool, .index, .i8, .i16, .i32, .u32, .i64, .f16, .f32 => true,
            else => false,
        };
    }

    /// SPIR-V's Aliasing rule says "behavior is undefined if operations on two distinct memory
    /// object declarations dynamically access the same memory locations" when one writes and
    /// neither is Aliased. A repeated alloca would make two pointer parameters alias that way.
    /// https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html#Aliasing
    fn admittedCallOperands(self: *Plan, call: FuncDialect.CallOp) PlanError!bool {
        var seen: std.AutoHashMapUnmanaged(*ir.Value, void) = .{};
        defer seen.deinit(self.allocator);
        for (call.getOperands()) |arg| {
            if (admittedScalar(arg.type)) continue;
            if (!admittedLocalMemref(arg.type)) return false;
            const defining: *ir.Operation = @ptrCast(@alignCast(arg.getDefiningOp() orelse return false));
            if (!std.mem.eql(u8, defining.name.name, MemrefDialect.AllocaOp.operation_name)) return false;
            const entry = try seen.getOrPut(self.allocator, arg);
            if (entry.found_existing) return false;
        }
        return true;
    }

    fn admittedScalar(typ: ir.Type) bool {
        const name = typ.getDialectTypeName() orelse return false;
        const kind = choir.dialects.arith.scalarKindFromTypeName(name) orelse return false;
        return switch (kind) {
            .bool, .index, .i8, .i16, .i32, .u32, .i64, .f16, .f32 => true,
            else => false,
        };
    }

    fn validateHelperBlock(block: *ir.Block) PlanError!void {
        var ops = block.getOperations();
        while (ops.next()) |op| {
            if (std.mem.startsWith(u8, op.name.name, "gpu.")) return error.UnsupportedOperation;
            for (0..op.getNumRegions()) |index| {
                const region = op.getRegion(index) orelse continue;
                var blocks = region.getBlocks();
                while (blocks.next()) |nested| try validateHelperBlock(nested);
            }
        }
    }

    fn walkCalls(self: *Plan, block: *ir.Block, depth: usize, stage: bool) PlanError!Mark {
        var height: Mark = if (stage) try self.preflightStageCalls(block, depth) else 0;
        var ops = block.getOperations();
        while (ops.next()) |op| {
            if (stage and !gpu.stage.admitsMemory(op)) {
                if (self.refused) |name| name.* = op.name.name;
                return error.UnsupportedStageMemory;
            }
            if (std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name)) {
                const call = FuncDialect.CallOp{ .op = op };
                const name = call.getCallee() orelse return error.UnsupportedOperation;
                const callee = self.function(name) orelse return error.UnsupportedOperation;
                if (!stage) height = @max(height, 1 + try self.visitHelper(callee, depth, false));
            }
            for (0..op.getNumRegions()) |index| {
                const region = op.getRegion(index) orelse continue;
                var blocks = region.getBlocks();
                while (blocks.next()) |nested| height = @max(height, try self.walkCalls(nested, depth, stage));
            }
        }
        return height;
    }

    fn preflightStageCalls(self: *Plan, block: *ir.Block, depth: usize) PlanError!Mark {
        var height: Mark = 0;
        var ops = block.getOperations();
        while (ops.next()) |op| {
            if (!std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name)) continue;
            const call = FuncDialect.CallOp{ .op = op };
            const name = call.getCallee() orelse return error.UnsupportedOperation;
            const callee = self.function(name) orelse return error.UnsupportedOperation;
            if (!try self.admittedCallOperands(call)) {
                if (self.refused) |why| why.* = name;
                return error.UnsupportedHelperSignature;
            }
            height = @max(height, 1 + try self.visitHelper(callee, depth, true));
        }
        return height;
    }
};
