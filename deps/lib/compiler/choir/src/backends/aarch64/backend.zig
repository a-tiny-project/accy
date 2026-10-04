const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const artifact = @import("../root.zig").artifact;
const machine = @import("../root.zig").machine_code;
const data = @import("../data.zig");
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
const fixture = @import("fixture/run.zig");

const Allocator = std.mem.Allocator;
const BackendError = interface.BackendError;
const ArithDialect = dialects.ArithDialect;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const MemrefDialect = dialects.MemrefDialect;
const memref = dialects.memref;
const GPR = registers.GPR;
const FPR = registers.FPR;
const Instruction = encoding.Instruction;

pub const supports_native_execution = sys.capabilities.current.supportsAarch64Execution();

pub const max_arguments: usize = 8;
pub const max_results: usize = 1;

pub const Backend = struct {
    allocator: Allocator,
    ctx: *ir.Context,

    pub fn init(allocator: Allocator, ctx: *ir.Context) Allocator.Error!Backend {
        try contract.loadArithDialect(ctx);
        return .{
            .allocator = allocator,
            .ctx = ctx,
        };
    }

    pub fn deinit(_: *Backend) void {}

    pub fn verify(_: *Backend, module: *ir.Operation) BackendError!void {
        try lowerModule(module);
    }

    pub fn lower(self: *Backend, module: *ir.Operation) BackendError!*ir.Operation {
        try self.verify(module);
        return module;
    }

    pub fn compileFunctionToMachineCode(
        self: *Backend,
        module: *ir.Operation,
        function_name: []const u8,
    ) BackendError![]u8 {
        const lowered = try self.lower(module);
        const func = ir.inspection.functionDefinitionByName(lowered, function_name) orelse return BackendError.FunctionNotFound;
        if (firstGlobalDeclaration(lowered)) |global|
            return refuse(global, "raw aarch64 bytes cannot carry global data", BackendError.UnsupportedOperation);

        var emitter = Emitter.init(self.allocator);
        defer emitter.deinit();
        try emitter.emitFunction(func);

        if (emitter.calls.items.len != 0)
            return refuse(emitter.first_call_operation.?, "raw aarch64 bytes cannot carry unresolved direct calls", BackendError.UnsupportedOperation);
        if (emitter.data_relocations.items.len != 0)
            return refuse(emitter.first_data_operation.?, "raw aarch64 bytes cannot carry unresolved global addresses", BackendError.UnsupportedOperation);

        const code = emitter.code.items;
        if (code.len == 0) return BackendError.CodeGenFailed;
        return self.allocator.dupe(u8, code) catch BackendError.OutOfMemory;
    }

    pub fn compileFunctionToArtifact(
        self: *Backend,
        module: *ir.Operation,
        function_name: []const u8,
    ) BackendError!artifact.Artifact {
        const lowered = try self.lower(module);
        const func = ir.inspection.functionDefinitionByName(lowered, function_name) orelse
            return BackendError.FunctionNotFound;
        if (firstGlobalDeclaration(lowered)) |global|
            return refuse(global, "aarch64 artifacts cannot carry global data", BackendError.UnsupportedOperation);
        const signature = boundary.ofFunction(func) catch return BackendError.UnsupportedOperation;
        var emitter = Emitter.init(self.allocator);
        defer emitter.deinit();
        try emitter.emitFunction(func);
        try emitter.padCodeToImageAlignment();
        if (emitter.code.items.len == 0) return BackendError.CodeGenFailed;
        if (emitter.data_relocations.items.len != 0)
            return refuse(emitter.first_data_operation.?, "aarch64 artifacts cannot carry global data relocations", BackendError.UnsupportedOperation);
        const relocations = self.allocator.alloc(artifact.Relocation, emitter.calls.items.len) catch return BackendError.OutOfMemory;
        defer self.allocator.free(relocations);
        for (emitter.calls.items, relocations) |call, *relocation| {
            relocation.* = .{ .offset = call.offset, .symbol = call.target, .kind = .call, .width_bits = 64 };
        }

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
            emitter.code.items,
            &.{},
            relocations,
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

/// The same verified scalar admission used by artifact emission and native execution.
pub fn lowerModule(module: *ir.Operation) BackendError!void {
    try contract.verifyModule("backend/aarch64/verify", module);
    _ = module.walk(.{ .order = .pre_order }, {}, refuseOverflow) catch
        return error.UnsupportedOperation;
    _ = module.walk(.{ .order = .pre_order }, {}, verifyBorrowedMemory) catch
        return error.UnsupportedOperation;
    var has_call = false;
    _ = module.walk(.{ .order = .pre_order }, &has_call, findCall) catch unreachable;
    if (has_call) try verifyCallGraph(module);
}

fn firstGlobalDeclaration(module: *ir.Operation) ?*ir.Operation {
    const region = module.getRegion(0) orelse return null;
    const block = region.getEntryBlock() orelse return null;
    var cursor = block.operations.head;
    while (cursor) |item| {
        const op: *ir.Operation = @ptrCast(@alignCast(item));
        cursor = op.next_op;
        if (std.mem.eql(u8, op.name.name, MemrefDialect.GlobalOp.operation_name)) return op;
    }
    return null;
}

fn findCall(has_call: *bool, op: *ir.Operation) ir.WalkResult {
    if (std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name)) has_call.* = true;
    return .advance;
}

/// A bounded direct graph is enough to rule out recursive stack growth in this first cut.
const max_call_functions = 64;
const CallGraph = struct {
    definitions: [max_call_functions]*ir.Operation = undefined,
    names: [max_call_functions][]const u8 = undefined,
    edges: [max_call_functions]u64 = @splat(0),
    count: usize = 0,
    current: usize = 0,
    failed_call: ?*ir.Operation = null,

    fn collect(self: *CallGraph, op: *ir.Operation) error{UnsupportedOperation}!ir.WalkResult {
        if (!std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name)) return .advance;
        const call = FuncDialect.CallOp{ .op = op };
        const reference = call.getCalleeRef() orelse {
            self.failed_call = op;
            return error.UnsupportedOperation;
        };
        if (!reference.isFlat()) {
            self.failed_call = op;
            return error.UnsupportedOperation;
        }
        const name = reference.getRootReference();
        if (op.operands.items.len > max_arguments or op.results.items.len > max_results) {
            self.failed_call = op;
            return error.UnsupportedOperation;
        }
        var floating_width: ?dialects.arith.ScalarKind = null;
        for (op.operands.items) |operand| {
            if (borrowedKind(operand.value.type) != null) continue;
            _ = scalarArgumentKind(false, op, operand.value.type) catch {
                self.failed_call = op;
                return error.UnsupportedOperation;
            };
            if (!sameFloatingWidth(&floating_width, operand.value.type)) {
                self.failed_call = op;
                return error.UnsupportedOperation;
            }
        }
        for (op.results.items) |result| {
            _ = scalarArgumentKind(false, op, result.type) catch {
                self.failed_call = op;
                return error.UnsupportedOperation;
            };
            if (!sameFloatingWidth(&floating_width, result.type)) {
                self.failed_call = op;
                return error.UnsupportedOperation;
            }
        }
        for (self.names[0..self.count], 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, name)) {
                self.edges[self.current] |= @as(u64, 1) << @as(u6, @intCast(index));
                break;
            }
        }
        return .advance;
    }
};

fn verifyCallGraph(module: *ir.Operation) BackendError!void {
    var graph: CallGraph = .{};
    const block = module.getRegion(0).?.getEntryBlock().?;
    var cursor = block.operations.head;
    while (cursor) |item| {
        const op: *ir.Operation = @ptrCast(@alignCast(item));
        cursor = op.next_op;
        if (!std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) continue;
        const function = FuncDialect.FuncOp{ .op = op };
        if (!function.hasBody()) continue;
        if (graph.count == max_call_functions)
            return refuse(op, "aarch64 direct calls exceed 64 defined functions", error.UnsupportedOperation);
        graph.definitions[graph.count] = op;
        graph.names[graph.count] = function.getName() orelse
            return refuse(op, "aarch64 direct call function has no name", error.UnsupportedOperation);
        graph.count += 1;
    }
    for (graph.definitions[0..graph.count], 0..) |definition, index| {
        graph.current = index;
        _ = definition.walk(.{ .order = .pre_order }, &graph, CallGraph.collect) catch
            return refuse(graph.failed_call orelse definition, "aarch64 direct call requires a flat name and scalar register arguments", error.UnsupportedOperation);
    }
    for (0..graph.count) |through| {
        const bit = @as(u64, 1) << @as(u6, @intCast(through));
        for (0..graph.count) |source| {
            if (graph.edges[source] & bit != 0) graph.edges[source] |= graph.edges[through];
        }
    }
    for (0..graph.count) |index| {
        const bit = @as(u64, 1) << @as(u6, @intCast(index));
        if (graph.edges[index] & bit != 0)
            return refuse(graph.definitions[index], "aarch64 direct calls require an acyclic graph", error.UnsupportedOperation);
    }
}

/// Refuse overflow roots even when their results are unused or outside the selected function.
fn refuseOverflow(_: void, op: *ir.Operation) error{UnsupportedOperation}!ir.WalkResult {
    inline for (.{ ArithDialect.AddoOp, ArithDialect.SuboOp, ArithDialect.MuloOp }) |Op| {
        if (std.mem.eql(u8, op.name.name, Op.operation_name)) return error.UnsupportedOperation;
    }
    return .advance;
}

const BorrowedKind = enum { byte, word };

/// The boundary signature records only an address word. The IR type, not that erased
/// signature, must establish host storage and the exact layout this emitter understands.
fn borrowedKind(typ: ir.Type) ?BorrowedKind {
    const params = dialects.memref.paramsOf(typ) orelse return null;
    if (params.addr_space != .host) return null;
    const key = typ.getDialectParamKey() orelse return null;
    var sections = std.mem.splitScalar(u8, key, ';');
    var base = std.mem.splitScalar(u8, sections.next() orelse return null, ',');
    _ = base.next() orelse return null;
    _ = base.next() orelse return null;
    _ = base.next() orelse return null;
    if (base.next() != null) return null;
    if (sections.next()) |annotation| {
        if (!std.mem.eql(u8, annotation, "indexing=i64")) return null;
        if (sections.next() != null) return null;
    }
    const element = dialects.arith.scalarKindFromTypeName(params.element_type_name) orelse return null;
    return switch (element) {
        .i8, .u8 => .byte,
        .i64, .u64, .index => .word,
        else => null,
    };
}

fn isIndex(typ: ir.Type) bool {
    const name = typ.getDialectTypeName() orelse return false;
    return dialects.arith.scalarKindFromTypeName(name) == .index;
}

fn isWordValueOf(value: *ir.Value, memref_value: *ir.Value) bool {
    const params = dialects.memref.paramsOf(memref_value.type) orelse return false;
    const name = value.type.getDialectTypeName() orelse return false;
    return std.mem.eql(u8, name, params.element_type_name);
}

/// This first stack cut owns an entry-local, positive, default-layout word
/// extent. The payload is uninitialized until the IR stores each word it reads.
fn allocaWordCount(op: *ir.Operation) ?usize {
    const alloca = MemrefDialect.AllocaOp{ .op = op };
    if (alloca.getDynamicSize() != null or op.getNumAttrs() != 0) return null;
    const result = alloca.getResult();
    if (borrowedKind(result.type) != .word) return null;
    const params = dialects.memref.paramsOf(result.type) orelse return null;
    const words = params.size orelse return null;
    if (words == 0 or words > placement.max_frame_slots) return null;
    const parent = op.getParentOp() orelse return null;
    if (!std.mem.eql(u8, parent.name.name, FuncDialect.FuncOp.operation_name)) return null;
    if (op.getBlock() != (FuncDialect.FuncOp{ .op = parent }).getEntryBlock()) return null;
    return @intCast(words);
}

fn allocaUsesAreLocal(result: *ir.Value) bool {
    var uses = result.useIterator();
    while (uses.next()) |operand| {
        const user: *ir.Operation = @ptrCast(@alignCast(operand.owner));
        if (std.mem.eql(u8, user.name.name, MemrefDialect.LoadOp.operation_name)) {
            if ((MemrefDialect.LoadOp{ .op = user }).getMemref() == result) continue;
        } else if (std.mem.eql(u8, user.name.name, MemrefDialect.StoreOp.operation_name)) {
            if ((MemrefDialect.StoreOp{ .op = user }).getMemref() == result) continue;
        }
        return false;
    }
    return true;
}

/// The first global cut owns only initialized, read-only host words. An address
/// remains private to direct loads; it cannot escape through a call, return,
/// view, store, or a region edge.
fn readOnlyGlobalSymbol(op: *ir.Operation) ?machine.DataSymbol {
    const global = MemrefDialect.GlobalOp{ .op = op };
    if (op.getNumAttrs() != 5) return null;
    const parent = op.getParentOp() orelse return null;
    if (!std.mem.eql(u8, parent.name.name, BuiltinDialect.ModuleOp.operation_name)) return null;
    if (parent.getParentOp() != null) return null;
    if (op.getBlock() != parent.getRegion(0).?.getEntryBlock()) return null;
    const typ = global.getType() orelse return null;
    if (borrowedKind(typ) != .word) return null;
    const key = typ.getDialectParamKey() orelse return null;
    if (std.mem.indexOfScalar(u8, key, ';') != null) return null;
    const global_placement = global.getPlacement() orelse return null;
    if (global_placement != .read_only) return null;
    const alignment = global.getAlignment() orelse return null;
    if (alignment < placement.slot_bytes) return null;
    const bytes = global.getInitial() orelse return null;
    if (bytes.len == 0 or bytes.len % placement.slot_bytes != 0) return null;
    return data.symbolOfGlobal(global) catch null;
}

fn globalNameIsUnique(op: *ir.Operation) bool {
    const name = (MemrefDialect.GlobalOp{ .op = op }).getSymName() orelse return false;
    const block = op.getBlock() orelse return false;
    var cursor = block.operations.head;
    while (cursor) |item| {
        const candidate: *ir.Operation = @ptrCast(@alignCast(item));
        cursor = candidate.next_op;
        if (candidate == op or !std.mem.eql(u8, candidate.name.name, MemrefDialect.GlobalOp.operation_name)) continue;
        const other = (MemrefDialect.GlobalOp{ .op = candidate }).getSymName() orelse continue;
        if (std.mem.eql(u8, name, other)) return false;
    }
    return true;
}

fn enclosingModule(op: *ir.Operation) ?*ir.Operation {
    var parent = op.getParentOp();
    while (parent) |candidate| : (parent = candidate.getParentOp()) {
        if (std.mem.eql(u8, candidate.name.name, BuiltinDialect.ModuleOp.operation_name)) return candidate;
    }
    return null;
}

fn globalUsesAreLoads(result: *ir.Value) bool {
    var uses = result.useIterator();
    while (uses.next()) |operand| {
        const user: *ir.Operation = @ptrCast(@alignCast(operand.owner));
        if (!std.mem.eql(u8, user.name.name, MemrefDialect.LoadOp.operation_name) or
            (MemrefDialect.LoadOp{ .op = user }).getMemref() != result) return false;
    }
    return true;
}

/// Check every memory operation in the module, including unused operations and functions.
/// Load/Store have one word index; View has an unscaled byte offset and a static word result.
fn verifyBorrowedMemory(_: void, op: *ir.Operation) BackendError!ir.WalkResult {
    if (!std.mem.startsWith(u8, op.name.name, "memref.")) return .advance;
    if (std.mem.eql(u8, op.name.name, MemrefDialect.GlobalOp.operation_name)) {
        if (readOnlyGlobalSymbol(op) == null or !globalNameIsUnique(op))
            return refuse(op, "aarch64 global requires initialized read-only default-layout host words aligned to a word", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.GetGlobalOp.operation_name)) {
        if (op.getNumAttrs() != 1)
            return refuse(op, "aarch64 global reference has unsupported attributes", error.UnsupportedOperation);
        const reference = MemrefDialect.GetGlobalOp{ .op = op };
        const name = reference.getSymName() orelse
            return refuse(op, "aarch64 global reference requires a name", error.UnsupportedOperation);
        const global = memref.findGlobal(op, name) orelse
            return refuse(op, "aarch64 global reference requires a declared global", error.UnsupportedOperation);
        const typ = global.getType() orelse
            return refuse(op, "aarch64 global reference requires a declared type", error.UnsupportedOperation);
        if (global.op.getParentOp() != enclosingModule(op) or !globalNameIsUnique(global.op) or
            readOnlyGlobalSymbol(global.op) == null or !reference.getResult().type.eql(typ) or
            !globalUsesAreLoads(reference.getResult()))
            return refuse(op, "aarch64 global reference requires an exact read-only host word type and only direct loads", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.AllocaOp.operation_name)) {
        const result = (MemrefDialect.AllocaOp{ .op = op }).getResult();
        if (allocaWordCount(op) == null or !allocaUsesAreLocal(result))
            return refuse(op, "aarch64 alloca requires a positive entry-local host word extent with only direct load/store uses", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.LoadOp.operation_name)) {
        const load = MemrefDialect.LoadOp{ .op = op };
        if (borrowedKind(load.getMemref().type) != .word or !isIndex(load.getIndex().type) or
            !isWordValueOf(load.getResult(), load.getMemref()) or
            op.getAttr("cache") != null or op.getAttr("eviction") != null)
            return refuse(op, "aarch64 load requires a default-cache host word memref, index and matching word result", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.StoreOp.operation_name)) {
        const store = MemrefDialect.StoreOp{ .op = op };
        if (borrowedKind(store.getMemref().type) != .word or !isIndex(store.getIndex().type) or
            !isWordValueOf(store.getValue(), store.getMemref()) or
            op.getAttr("cache") != null or op.getAttr("eviction") != null)
            return refuse(op, "aarch64 store requires a default-cache host word memref, index and matching word value", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.ViewOp.operation_name)) {
        const view = MemrefDialect.ViewOp{ .op = op };
        const result = view.getResult();
        const result_params = dialects.memref.paramsOf(result.type) orelse
            return refuse(op, "aarch64 view requires a static host word result", error.UnsupportedOperation);
        if (borrowedKind(view.getBase().type) != .byte or !isIndex(view.getByteOffset().type) or
            borrowedKind(result.type) != .word or result_params.size == null)
            return refuse(op, "aarch64 view requires a host byte base, byte offset index and static host word result", error.UnsupportedOperation);
        return .advance;
    }
    return refuse(op, "aarch64 defers this memory operation", error.UnsupportedOperation);
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

pub const Emitter = struct {
    allocator: Allocator,
    code: std.ArrayListUnmanaged(u8) = .empty,
    calls: std.ArrayListUnmanaged(machine.CallRelocation) = .empty,
    data_symbols: machine.DataSymbolSet = .{},
    data_relocations: std.ArrayListUnmanaged(machine.DataRelocation) = .empty,
    plan: placement.Plan = .{},
    diagnose: bool = true,
    failed_operation: ?*ir.Operation = null,
    first_call_operation: ?*ir.Operation = null,
    first_data_operation: ?*ir.Operation = null,
    active_operation: ?*ir.Operation = null,
    reservation_before_emit: usize = 0,

    pub fn init(allocator: Allocator) Emitter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Emitter) void {
        self.code.deinit(self.allocator);
        self.calls.deinit(self.allocator);
        self.data_symbols.deinit(self.allocator);
        self.data_relocations.deinit(self.allocator);
    }

    /// A retained compiler can emit another function after the runtime has taken its code.
    pub fn discard(self: *Emitter) void {
        self.code.clearRetainingCapacity();
        self.calls.clearRetainingCapacity();
        self.data_symbols.clearRetainingCapacity();
        self.data_relocations.clearRetainingCapacity();
        self.plan = .{};
        self.failed_operation = null;
        self.first_call_operation = null;
        self.first_data_operation = null;
        self.active_operation = null;
        self.reservation_before_emit = 0;
    }

    /// Emits the verified finite block in order, including unused effects.
    pub fn emitFunction(self: *Emitter, func: *ir.Operation) BackendError!void {
        std.debug.assert(self.code.items.len == 0);
        self.failed_operation = null;
        self.first_call_operation = null;
        self.first_data_operation = null;
        self.active_operation = func;
        self.reservation_before_emit = self.code.capacity;
        errdefer if (self.failed_operation == null) {
            self.failed_operation = self.active_operation;
        };
        const function = FuncDialect.FuncOp{ .op = func };
        if (!function.hasBody() or function.getBody().blocks.size != 1) {
            return self.reject(func, "aarch64 emission requires a single defined block", BackendError.UnsupportedOperation);
        }
        if (function.getNumArguments() > max_arguments) {
            return self.reject(func, std.fmt.comptimePrint("aarch64 emission exceeds {d} arguments", .{max_arguments}), BackendError.UnsupportedOperation);
        }
        if (function.getNumResults() > max_results) {
            return self.reject(func, std.fmt.comptimePrint("aarch64 emission exceeds {d} result", .{max_results}), BackendError.UnsupportedOperation);
        }
        var floating_width: ?dialects.arith.ScalarKind = null;
        for (function.getArguments()) |arg| {
            if (!sameFloatingWidth(&floating_width, arg.type))
                return self.reject(func, "aarch64 function mixes f32 and f64 ABI banks", BackendError.UnsupportedOperation);
            if (isFloating(arg.type)) try self.requireFloatingPolicy(func);
        }
        for (function.getResultTypes()) |typ| {
            if (!sameFloatingWidth(&floating_width, typ))
                return self.reject(func, "aarch64 function mixes f32 and f64 ABI banks", BackendError.UnsupportedOperation);
            if (isFloating(typ)) try self.requireFloatingPolicy(func);
        }
        self.plan.build(function.getEntryBlock()) catch |err| {
            const message = switch (err) {
                error.ValueCapacity => std.fmt.comptimePrint("aarch64 placement exceeds {d} tracked values", .{placement.max_values}),
                error.FrameCapacity => std.fmt.comptimePrint("aarch64 placement exceeds {d} frame slots", .{placement.max_frame_slots}),
                error.OperationCapacity => std.fmt.comptimePrint("aarch64 placement exceeds {d} operations", .{placement.max_operations}),
                error.ControlShape => "aarch64 structured control requires matching single-block regions and terminal yield/condition",
                error.ControlType => "aarch64 structured control requires scalar integer or floating values, bool conditions and index induction",
                error.CarriedCapacity => std.fmt.comptimePrint("aarch64 control exceeds {d} carried or region-result values", .{control.max_carried_values}),
                error.DepthCapacity => std.fmt.comptimePrint("aarch64 control exceeds {d} nested constructs", .{control.max_depth}),
                error.MissingValue => "aarch64 operand has no preceding definition",
            };
            return self.reject(self.plan.refused_operation.?, message, BackendError.UnsupportedOperation);
        };
        for (self.plan.events[0..self.plan.event_count]) |event| {
            if (event.kind != .operation or !std.mem.eql(u8, event.op.name.name, FuncDialect.CallOp.operation_name)) continue;
            self.plan.reserveCallFrame(event.op) catch
                return self.reject(event.op, std.fmt.comptimePrint("aarch64 calls exceed {d} total frame slots", .{placement.max_frame_slots}), BackendError.UnsupportedOperation);
            break;
        }
        for (self.plan.events[0..self.plan.event_count]) |event| {
            if (event.kind != .operation or !std.mem.eql(u8, event.op.name.name, MemrefDialect.AllocaOp.operation_name)) continue;
            const result = (MemrefDialect.AllocaOp{ .op = event.op }).getResult();
            const words = allocaWordCount(event.op) orelse
                return self.reject(event.op, "aarch64 alloca requires a positive entry-local host word extent", BackendError.UnsupportedOperation);
            self.plan.reserveAlloca(event.op, result, words) catch
                return self.reject(event.op, std.fmt.comptimePrint("aarch64 alloca exceeds {d} total frame slots", .{placement.max_frame_slots}), BackendError.UnsupportedOperation);
        }
        if (self.plan.frameBytes() != 0) {
            try self.emitInstruction(encoding.AddSubImmediate.sub(registers.SP.encoded, registers.SP.encoded, @intCast(self.plan.frameBytes()), .x));
        }
        if (self.plan.call_save_base) |base| {
            const record = (@as(usize, base) + placement.call_save_slots) * placement.slot_bytes;
            try self.emitInstruction(encoding.LoadStorePair.stpBytes(GPR.x29.encode(), GPR.x30.encode(), registers.SP.encoded, @intCast(record), .x));
            try self.emitInstruction(encoding.AddSubImmediate.add(GPR.x29.encode(), registers.SP.encoded, @intCast(record), .x));
        }
        // The hardware x and d banks advance independently. First move integer
        // arguments rightward into positional homes, then copy floating bits;
        // (float,i64) must not overwrite physical x0 before x0 is relocated.
        var integer_count: usize = 0;
        for (function.getArguments()) |arg| if (!isFloating(arg.type)) {
            if (borrowedKind(arg.type) == null) _ = try scalarIntegerKind(self.diagnose, func, arg.type);
            integer_count += 1;
        };
        var next_integer = integer_count;
        for (0..function.getNumArguments()) |reverse| {
            const ordinal = function.getNumArguments() - reverse - 1;
            const arg = function.getArgument(ordinal);
            if (isFloating(arg.type)) continue;
            next_integer -= 1;
            const target = argumentRegister(@intCast(ordinal));
            try self.move(target, argumentRegister(@intCast(next_integer)));
            if (borrowedKind(arg.type) == null)
                try self.normalize(target, try scalarIntegerKind(self.diagnose, func, arg.type));
        }
        var floating_index: usize = 0;
        for (function.getArguments(), 0..) |arg, ordinal| {
            if (!isFloating(arg.type)) continue;
            try self.emitInstruction(if (isF32(arg.type))
                encoding.FMovGeneral.fmovFromFprSingle(argumentRegister(@intCast(ordinal)).encode(), floatArgumentRegister(@intCast(floating_index)).encode())
            else
                encoding.FMovGeneral.fmovFromFprDouble(argumentRegister(@intCast(ordinal)).encode(), floatArgumentRegister(@intCast(floating_index)).encode()));
            floating_index += 1;
        }
        for (function.getResultTypes()) |typ| _ = try scalarArgumentKind(self.diagnose, func, typ);

        try self.emitSchedule(function);
    }

    /// Canonical images concatenate functions. Their sizes must keep subsequent call slots
    /// eight-byte aligned; raw byte emission keeps its historical leaf encoding unchanged.
    pub fn padCodeToImageAlignment(self: *Emitter) BackendError!void {
        if (self.code.items.len % 8 != 0) try self.emitInstruction(.{ .raw = 0xd503201f });
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
            self.active_operation = op;
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
                if (event.depth == 0) return self.reject(op, "aarch64 yield requires a structured region", BackendError.UnsupportedOperation);
                const parent = frames[event.depth - 1].op;
                if (op.next_op != null) return self.reject(op, "aarch64 yield must terminate its region", BackendError.UnsupportedOperation);
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
                        if (op != control.last(parent.regions.items[1].getEntryBlock().?)) return self.reject(op, "aarch64 while yield must terminate the after region", BackendError.UnsupportedOperation);
                        try self.transfer(op, op.getOperandValues(), .{ .arguments = before.arguments.items });
                    },
                }
                continue;
            }
            if (control.is(op, dialects.ScfDialect.ConditionOp.operation_name)) {
                if (event.depth == 0) return self.reject(op, "aarch64 condition requires while before region", BackendError.UnsupportedOperation);
                const frame = &frames[event.depth - 1];
                if (control.kind(frame.op).? != .repeated or op != control.last(frame.op.regions.items[0].getEntryBlock().?)) return self.reject(op, "aarch64 condition must terminate while before region", BackendError.UnsupportedOperation);
                frame.condition = op;
                continue;
            }
            if (control.is(op, FuncDialect.ReturnOp.operation_name)) {
                if (event.depth != 0 or op.next_op != null) return self.reject(op, "aarch64 return must end the function block", BackendError.UnsupportedOperation);
                std.debug.assert(op.operands.items.len == function.getNumResults());
                if (op.operands.items.len == 1) {
                    const source = try self.location(op, op.operands.items[0].value, .x8);
                    if (isFloating(op.operands.items[0].value.type))
                        try self.emitInstruction(if (isF32(op.operands.items[0].value.type))
                            encoding.FMovGeneral.fmovToFprSingle(FPR.v0.encode(), source.encode())
                        else
                            encoding.FMovGeneral.fmovToFprDouble(FPR.v0.encode(), source.encode()))
                    else
                        try self.move(.x0, source);
                }
                if (self.plan.call_save_base) |base| {
                    const record = (@as(usize, base) + placement.call_save_slots) * placement.slot_bytes;
                    try self.emitInstruction(encoding.LoadStorePair.ldpBytes(GPR.x29.encode(), GPR.x30.encode(), registers.SP.encoded, @intCast(record), .x));
                }
                if (self.plan.frameBytes() != 0) try self.emitInstruction(encoding.AddSubImmediate.add(registers.SP.encoded, registers.SP.encoded, @intCast(self.plan.frameBytes()), .x));
                try self.emitInstruction(encoding.UnconditionalBranchReg.retLr());
                return;
            }
            try self.emitOperation(op);
        }
        return self.reject(function.op, "aarch64 function requires func.return", BackendError.UnsupportedOperation);
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
        return self.reject(op, "aarch64 operand has no placement", BackendError.CodeGenFailed);
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
            encoding.ConditionalBranch.bCond(cond, std.math.cast(i19, distance) orelse return self.reject(op, "aarch64 conditional branch exceeds signed 19-bit instruction displacement", BackendError.UnsupportedOperation))
        else
            encoding.UnconditionalBranchImm.b(std.math.cast(i26, distance) orelse return self.reject(op, "aarch64 branch exceeds signed 26-bit instruction displacement", BackendError.UnsupportedOperation));
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
        bitcast,
        umulhi,
        popcount,
    };

    /// Reads temporary operands before writing a potentially recycled home.
    fn emitOperation(self: *Emitter, op: *ir.Operation) BackendError!void {
        const admitted = @import("root.zig").admission.lookup(op.name.name);
        if (admitted == null or admitted.?.status != .admitted) {
            return self.reject(op, "aarch64 emission defers this operation", BackendError.UnsupportedOperation);
        }
        if (std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name)) return self.emitCall(op);
        if (std.mem.eql(u8, op.name.name, MemrefDialect.GetGlobalOp.operation_name)) return self.emitGlobalAddress(op);
        if (std.mem.eql(u8, op.name.name, MemrefDialect.AllocaOp.operation_name)) return self.emitAlloca(op);
        if (std.mem.eql(u8, op.name.name, MemrefDialect.LoadOp.operation_name) or
            std.mem.eql(u8, op.name.name, MemrefDialect.StoreOp.operation_name) or
            std.mem.eql(u8, op.name.name, MemrefDialect.ViewOp.operation_name)) return self.emitBorrowedMemory(op);
        const operation = std.meta.stringToEnum(ScalarOp, op.name.name["arith.".len..]) orelse
            return self.reject(op, "aarch64 emission defers this operation", BackendError.UnsupportedOperation);
        std.debug.assert(op.results.items.len == 1);
        const value = op.getResult(0).?;
        if (isFloating(value.type) or (operation == .cast and isFloating(op.operands.items[0].value.type)) or
            (operation == .cmp and isFloating(op.operands.items[0].value.type)) or
            (operation == .bitcast and isFloating(op.operands.items[0].value.type)))
            return self.emitFloating(op, operation);
        const kind = try scalarIntegerKind(self.diagnose, op, value.type);
        for (op.operands.items) |operand| _ = try scalarIntegerKind(self.diagnose, op, operand.value.type);
        if (operation == .constant) {
            const integer = (ArithDialect.ConstantOp{ .op = op }).getIntValue() orelse boolean: {
                const attr = op.getAttrAs(ir.Attribute.BoolAttr, "value") orelse
                    return self.reject(op, "aarch64 constant requires an integer or boolean value", BackendError.UnsupportedOperation);
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
                const operand_kind = try scalarIntegerKind(self.diagnose, op, op.operands.items[0].value.type);
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
            .bitcast => return self.reject(op, "aarch64 bitcast requires exactly u64 and f64", BackendError.UnsupportedOperation),
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

    /// Floating live ranges remain raw words in the ordinary placement homes.
    /// Only v16/v17 hold transient operands; no FP register survives a call.
    fn emitFloating(self: *Emitter, op: *ir.Operation, operation: ScalarOp) BackendError!void {
        try self.requireFloatingPolicy(op);
        const float_to_int = operation == .cast and !isFloating(op.getResult(0).?.type) and
            isFloating(op.operands.items[0].value.type);
        const facts = ir.interfaces.effects;
        var storage: [7]facts.Fact = undefined;
        const declaration = facts.collectInto(op, &storage) catch
            return self.reject(op, "aarch64 floating effect declaration cannot be collected", BackendError.UnsupportedOperation);
        if (!declaration.complete) return self.reject(op, "aarch64 floating effect declaration is incomplete", BackendError.UnsupportedOperation);
        for (declaration.records) |record| switch (record) {
            .premise => |premise| if (premise != .floating_environment)
                return self.reject(op, "aarch64 floating operation requires the default floating environment", BackendError.UnsupportedOperation),
            .requirement => |requirement| {
                if (!float_to_int or requirement.kind != .conversion_representable) return self.reject(op, "aarch64 floating operation has unsupported effects", BackendError.UnsupportedOperation);
                switch (requirement.subject) {
                    .operand => |index| if (index != 0) return self.reject(op, "aarch64 floating conversion requires operand zero", BackendError.UnsupportedOperation),
                    else => return self.reject(op, "aarch64 floating conversion requires operand zero", BackendError.UnsupportedOperation),
                }
            },
            .event => |event| {
                if (!float_to_int or event.kind != .failure or event.failure_name == null or
                    !std.mem.eql(u8, event.failure_name.?, "InvalidFloatToInteger"))
                    return self.reject(op, "aarch64 floating operation has unsupported effects", BackendError.UnsupportedOperation);
            },
            else => {},
        };
        if (float_to_int) return self.emitFloatToInt(op);
        if (isF32(op.getResult(0).?.type) or
            (operation == .cmp and isF32(op.operands.items[0].value.type)))
            return self.emitF32(op, operation);
        const value = op.getResult(0).?;
        const float_result = isF64(value.type);
        switch (operation) {
            .constant => {
                if (!float_result) return self.reject(op, "aarch64 floating constant requires f64", BackendError.UnsupportedOperation);
                const number = (ArithDialect.ConstantOp{ .op = op }).getFloatValue() orelse
                    return self.reject(op, "aarch64 floating constant requires a float attribute", BackendError.UnsupportedOperation);
                if (value.hasNoUses()) return;
                const target = self.destination(value);
                try self.emitMoveImmediate(target, @bitCast(number));
                try self.store(value, target);
                return;
            },
            .bitcast => {
                const source = op.operands.items[0].value;
                if (!((float_result and isU64(source.type)) or (isU64(value.type) and isF64(source.type))))
                    return self.reject(op, "aarch64 bitcast requires exactly u64 and f64", BackendError.UnsupportedOperation);
                if (value.hasNoUses()) return;
                const register = try self.location(op, source, .x16);
                const target = self.destination(value);
                try self.move(target, register);
                try self.store(value, target);
                return;
            },
            .cast => {
                if (!float_result) return self.reject(op, "aarch64 numeric cast requires an f64 result", BackendError.UnsupportedOperation);
                const source = op.operands.items[0].value;
                const kind = try scalarIntegerKind(self.diagnose, op, source.type);
                if (kind == .bool) return self.reject(op, "aarch64 numeric cast requires an integer source", BackendError.UnsupportedOperation);
                if (value.hasNoUses()) return;
                const register = try self.location(op, source, .x16);
                try self.move(.x16, register);
                try self.normalize(.x16, kind);
                try self.emitInstruction(if (unsignedKind(kind))
                    encoding.FPConversion.ucvtfDoubleFromX(FPR.v16.encode(), GPR.x16.encode())
                else
                    encoding.FPConversion.scvtfDoubleFromX(FPR.v16.encode(), GPR.x16.encode()));
                const target = self.destination(value);
                try self.emitInstruction(encoding.FMovGeneral.fmovFromFprDouble(target.encode(), FPR.v16.encode()));
                try self.store(value, target);
                return;
            },
            .add, .sub, .mul, .div, .neg, .abs, .select, .cmp => {},
            else => return self.reject(op, "aarch64 defers this floating operation", BackendError.UnsupportedOperation),
        }
        if ((operation == .cmp) == float_result)
            return self.reject(op, "aarch64 f64 comparison requires a boolean result", BackendError.UnsupportedOperation);
        for (op.operands.items, 0..) |operand, index| {
            if (operation == .select and index == 0) {
                if (!isBool(operand.value.type)) return self.reject(op, "aarch64 floating select requires a boolean condition", BackendError.UnsupportedOperation);
            } else if (!isF64(operand.value.type)) {
                return self.reject(op, "aarch64 floating operation requires f64 operands", BackendError.UnsupportedOperation);
            }
        }
        const scratch = [_]GPR{ .x16, .x17, .x8 };
        for (op.operands.items, 0..) |operand, index| {
            const source = try self.location(op, operand.value, scratch[index]);
            try self.move(scratch[index], source);
        }
        if (value.hasNoUses()) return;
        const target = self.destination(value);
        switch (operation) {
            .add, .sub, .mul, .div => {
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v16.encode(), GPR.x16.encode()));
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v17.encode(), GPR.x17.encode()));
                const inst = switch (operation) {
                    .add => encoding.FP2Source.fadd(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), .double),
                    .sub => encoding.FP2Source.fsub(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), .double),
                    .mul => encoding.FP2Source.fmul(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), .double),
                    .div => encoding.FP2Source.fdiv(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), .double),
                    else => unreachable,
                };
                try self.emitInstruction(inst);
                try self.emitInstruction(encoding.FMovGeneral.fmovFromFprDouble(target.encode(), FPR.v16.encode()));
            },
            .neg => {
                try self.emitMoveImmediate(.x17, 0x8000_0000_0000_0000);
                try self.emitInstruction(encoding.LogicalShiftedRegister.eorReg(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x));
            },
            .abs => {
                try self.emitMoveImmediate(.x17, 0x7fff_ffff_ffff_ffff);
                try self.emitInstruction(encoding.LogicalShiftedRegister.andReg(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x));
            },
            .select => {
                try self.emitInstruction(encoding.AddSubImmediate.cmpImm(GPR.x16.encode(), 0, .x));
                try self.emitInstruction(encoding.ConditionalSelect.csel(target.encode(), GPR.x17.encode(), GPR.x8.encode(), .ne, .x));
            },
            .cmp => {
                const predicate = (ArithDialect.CmpOp{ .op = op }).getPredicate() orelse
                    return self.reject(op, "aarch64 f64 comparison requires a predicate", BackendError.UnsupportedOperation);
                const condition: encoding.Condition = switch (predicate) {
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .mi,
                    .le => .ls,
                    .gt => .gt,
                    .ge => .ge,
                    else => return self.reject(op, "aarch64 f64 comparison requires eq/ne/lt/le/gt/ge", BackendError.UnsupportedOperation),
                };
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v16.encode(), GPR.x16.encode()));
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v17.encode(), GPR.x17.encode()));
                try self.emitInstruction(encoding.FPCompare.fcmp(FPR.v16.encode(), FPR.v17.encode(), .double));
                try self.emitInstruction(encoding.ConditionalSelect.cset(target.encode(), condition, .x));
            },
            else => unreachable,
        }
        try self.store(value, target);
    }

    /// Guard the dialect's finite, truncating representability law before FCVTZ.
    /// The raw f64 source remains live in d16 while x17/d17 hold each bound.
    fn emitFloatToInt(self: *Emitter, op: *ir.Operation) BackendError!void {
        const source = op.operands.items[0].value;
        const value = op.getResult(0).?;
        if (!isF64(source.type)) return self.reject(op, "aarch64 float-to-integer cast requires f64", BackendError.UnsupportedOperation);
        const kind = try scalarIntegerKind(self.diagnose, op, value.type);
        if (kind == .bool) return self.reject(op, "aarch64 float-to-integer cast requires an integer result", BackendError.UnsupportedOperation);
        const bits = dialects.arith.scalarBitWidth(kind);
        const unsigned = unsignedKind(kind);
        if (source.getDefiningOp()) |raw| {
            const definition: *ir.Operation = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, definition.name.name, ArithDialect.ConstantOp.operation_name)) {
                if ((ArithDialect.ConstantOp{ .op = definition }).getFloatValue()) |number| {
                    if (dialects.arith.scalar.floatToInt(number, bits, !unsigned) == null)
                        return self.reject(op, "aarch64 InvalidFloatToInteger is statically certain", BackendError.UnsupportedOperation);
                }
            }
        }

        const register = try self.location(op, source, .x16);
        try self.move(.x16, register);
        try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v16.encode(), GPR.x16.encode()));
        const exponent: u7 = @intCast(bits - @as(u8, if (unsigned) 0 else 1));
        const upper: f64 = @floatFromInt(@as(u128, 1) << exponent);
        const lower: f64 = if (unsigned) -1 else if (bits == 64) -upper else -upper - 1;
        try self.emitMoveImmediate(.x17, @bitCast(lower));
        try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v17.encode(), GPR.x17.encode()));
        try self.emitInstruction(encoding.FPCompare.fcmp(FPR.v16.encode(), FPR.v17.encode(), .double));
        try self.requireCondition(if (!unsigned and bits == 64) .ge else .gt);
        try self.emitMoveImmediate(.x17, @bitCast(upper));
        try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v17.encode(), GPR.x17.encode()));
        try self.emitInstruction(encoding.FPCompare.fcmp(FPR.v16.encode(), FPR.v17.encode(), .double));
        try self.requireCondition(.mi);
        if (value.hasNoUses()) return;
        const target = self.destination(value);
        try self.emitInstruction(if (unsigned)
            encoding.FPConversion.fcvtzuXFromDouble(target.encode(), FPR.v16.encode())
        else
            encoding.FPConversion.fcvtzsXFromDouble(target.encode(), FPR.v16.encode()));
        try self.normalize(target, kind);
        try self.store(value, target);
    }

    /// The first binary32 cut has only Newton's scalar operations. Its values
    /// occupy ordinary zero-extended word homes; s16/s17 are transient.
    fn emitF32(self: *Emitter, op: *ir.Operation, operation: ScalarOp) BackendError!void {
        const value = op.getResult(0).?;
        if (operation == .constant) {
            if (!isF32(value.type))
                return self.reject(op, "aarch64 f32 constant requires an f32 result", BackendError.UnsupportedOperation);
            const number = (ArithDialect.ConstantOp{ .op = op }).getFloatValue() orelse
                return self.reject(op, "aarch64 f32 constant requires a float attribute", BackendError.UnsupportedOperation);
            if (value.hasNoUses()) return;
            const target = self.destination(value);
            const bits: u32 = @bitCast(@as(f32, @floatCast(number)));
            try self.emitMoveImmediate(target, bits);
            try self.store(value, target);
            return;
        }
        if (operation != .add and operation != .mul and operation != .div and operation != .cmp)
            return self.reject(op, "aarch64 defers this f32 operation", BackendError.UnsupportedOperation);
        if (operation == .cmp and !isBool(value.type))
            return self.reject(op, "aarch64 f32 comparison requires a boolean result", BackendError.UnsupportedOperation);
        if (operation != .cmp and !isF32(value.type))
            return self.reject(op, "aarch64 f32 operation requires an f32 result", BackendError.UnsupportedOperation);
        for (op.operands.items) |operand| if (!isF32(operand.value.type))
            return self.reject(op, "aarch64 f32 operation requires f32 operands", BackendError.UnsupportedOperation);
        if (operation == .cmp) {
            const predicate = (ArithDialect.CmpOp{ .op = op }).getPredicate() orelse
                return self.reject(op, "aarch64 f32 comparison requires eq", BackendError.UnsupportedOperation);
            if (predicate != .eq)
                return self.reject(op, "aarch64 f32 comparison requires eq", BackendError.UnsupportedOperation);
        }
        const source0 = try self.location(op, op.operands.items[0].value, .x16);
        try self.move(.x16, source0);
        const source1 = try self.location(op, op.operands.items[1].value, .x17);
        try self.move(.x17, source1);
        if (value.hasNoUses()) return;
        const target = self.destination(value);
        try self.emitInstruction(encoding.FMovGeneral.fmovToFprSingle(FPR.v16.encode(), GPR.x16.encode()));
        try self.emitInstruction(encoding.FMovGeneral.fmovToFprSingle(FPR.v17.encode(), GPR.x17.encode()));
        switch (operation) {
            .add => try self.emitInstruction(encoding.FP2Source.fadd(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), .single)),
            .mul => try self.emitInstruction(encoding.FP2Source.fmul(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), .single)),
            .div => try self.emitInstruction(encoding.FP2Source.fdiv(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), .single)),
            .cmp => {
                try self.emitInstruction(encoding.FPCompare.fcmp(FPR.v16.encode(), FPR.v17.encode(), .single));
                try self.emitInstruction(encoding.ConditionalSelect.cset(target.encode(), .eq, .x));
            },
            else => unreachable,
        }
        if (operation != .cmp)
            try self.emitInstruction(encoding.FMovGeneral.fmovFromFprSingle(target.encode(), FPR.v16.encode()));
        try self.store(value, target);
    }

    /// x16 is the computed address, x17 the element offset and x8 the scale or
    /// stored word. A spilled store value is reloaded only after address formation.
    fn emitBorrowedMemory(self: *Emitter, op: *ir.Operation) BackendError!void {
        _ = verifyBorrowedMemory({}, op) catch return BackendError.UnsupportedOperation;
        if (std.mem.eql(u8, op.name.name, MemrefDialect.ViewOp.operation_name)) {
            const view = MemrefDialect.ViewOp{ .op = op };
            const result = view.getResult();
            if (result.hasNoUses()) return;
            const base = try self.location(op, view.getBase(), .x16);
            try self.move(.x16, base);
            const offset = try self.location(op, view.getByteOffset(), .x17);
            try self.move(.x17, offset);
            const target = self.destination(result);
            try self.emitInstruction(encoding.AddSubShiftedRegister.addReg(target.encode(), GPR.x16.encode(), GPR.x17.encode(), .x));
            try self.store(result, target);
            return;
        }

        const is_load = std.mem.eql(u8, op.name.name, MemrefDialect.LoadOp.operation_name);
        const memref_value = if (is_load)
            (MemrefDialect.LoadOp{ .op = op }).getMemref()
        else
            (MemrefDialect.StoreOp{ .op = op }).getMemref();
        const index_value = if (is_load)
            (MemrefDialect.LoadOp{ .op = op }).getIndex()
        else
            (MemrefDialect.StoreOp{ .op = op }).getIndex();
        const base = try self.location(op, memref_value, .x16);
        try self.move(.x16, base);
        const index = try self.location(op, index_value, .x17);
        try self.move(.x17, index);
        try self.emitInstruction(encoding.MoveWide.movz(GPR.x8.encode(), 8, 0, .x));
        try self.emitInstruction(encoding.DataProcessing3Source.mul(GPR.x17.encode(), GPR.x17.encode(), GPR.x8.encode(), .x));
        try self.emitInstruction(encoding.AddSubShiftedRegister.addReg(GPR.x16.encode(), GPR.x16.encode(), GPR.x17.encode(), .x));
        if (is_load) {
            const value = (MemrefDialect.LoadOp{ .op = op }).getResult();
            const target = if (value.hasNoUses()) GPR.x8 else self.destination(value);
            try self.emitInstruction(encoding.LoadStoreRegImm.ldr(target.encode(), GPR.x16.encode(), 0, .x));
            if (!value.hasNoUses()) try self.store(value, target);
            return;
        }
        const value = (MemrefDialect.StoreOp{ .op = op }).getValue();
        const source = try self.location(op, value, .x8);
        try self.move(.x8, source);
        try self.emitInstruction(encoding.LoadStoreRegImm.str(GPR.x8.encode(), GPR.x16.encode(), 0, .x));
    }

    /// LDR literal / B-over-slot leaves one aligned eight-byte address for
    /// Runtime's checked data relocation. No instruction executes the slot.
    fn emitGlobalAddress(self: *Emitter, op: *ir.Operation) BackendError!void {
        _ = verifyBorrowedMemory({}, op) catch return BackendError.UnsupportedOperation;
        if (self.first_data_operation == null) self.first_data_operation = op;
        const reference = MemrefDialect.GetGlobalOp{ .op = op };
        const result = reference.getResult();
        if (result.hasNoUses()) return;
        const global = memref.findGlobal(op, reference.getSymName().?).?;
        const symbol = readOnlyGlobalSymbol(global.op).?;
        self.data_symbols.put(self.allocator, symbol) catch |err| switch (err) {
            error.OutOfMemory => return BackendError.OutOfMemory,
            else => return self.reject(op, "aarch64 global has conflicting data symbols", BackendError.UnsupportedOperation),
        };
        const start = self.code.items.len;
        const slot = std.mem.alignForward(usize, start + 2 * Instruction.size, 8);
        const load_displacement: i19 = @intCast((slot - start) / Instruction.size);
        const branch_displacement: i26 = @intCast((slot + 8 - (start + Instruction.size)) / Instruction.size);
        const target = self.destination(result);
        try self.emitInstruction(encoding.LoadLiteral.ldrX(target.encode(), load_displacement));
        try self.emitInstruction(encoding.UnconditionalBranchImm.b(branch_displacement));
        while (self.code.items.len < slot) try self.emitInstruction(.{ .raw = 0xd503201f });
        std.debug.assert(self.code.items.len == slot);
        self.code.appendNTimes(self.allocator, 0, 8) catch return BackendError.OutOfMemory;
        self.data_relocations.append(self.allocator, .{ .offset = slot, .target = symbol.name }) catch return BackendError.OutOfMemory;
        try self.store(result, target);
    }

    fn emitAlloca(self: *Emitter, op: *ir.Operation) BackendError!void {
        const result = (MemrefDialect.AllocaOp{ .op = op }).getResult();
        const slot = self.plan.allocaPayload(result) orelse
            return self.reject(op, "aarch64 alloca has no reserved payload", BackendError.UnsupportedOperation);
        if (result.hasNoUses()) return;
        const target = self.destination(result);
        const offset = @as(usize, slot) * placement.slot_bytes;
        try self.emitInstruction(encoding.AddSubImmediate.add(target.encode(), registers.SP.encoded, @intCast(offset), .x));
        try self.store(result, target);
    }

    const call_saved = [placement.call_save_slots]GPR{
        .x0, .x1,  .x2,  .x3,  .x4,  .x5,  .x6,  .x7,
        .x9, .x10, .x11, .x12, .x13, .x14, .x15,
    };

    /// Every source is read from its saved pre-call home, so argument permutations cannot
    /// destroy one another. x8 holds the returned word while old caller state is restored.
    fn emitCall(self: *Emitter, op: *ir.Operation) BackendError!void {
        if (self.first_call_operation == null) self.first_call_operation = op;
        const call = FuncDialect.CallOp{ .op = op };
        const reference = call.getCalleeRef() orelse return self.reject(op, "aarch64 call requires a direct callee", BackendError.UnsupportedOperation);
        if (!reference.isFlat()) return self.reject(op, "aarch64 call requires a flat direct callee", BackendError.UnsupportedOperation);
        const callee = reference.getRootReference();
        if (op.operands.items.len > max_arguments or op.results.items.len > max_results)
            return self.reject(op, "aarch64 call exceeds scalar register arguments or results", BackendError.UnsupportedOperation);
        var floating_width: ?dialects.arith.ScalarKind = null;
        for (op.operands.items) |operand| {
            if (!sameFloatingWidth(&floating_width, operand.value.type))
                return self.reject(op, "aarch64 call mixes f32 and f64 ABI banks", BackendError.UnsupportedOperation);
            if (isFloating(operand.value.type)) try self.requireFloatingPolicy(op);
        }
        for (op.results.items) |result| {
            if (!sameFloatingWidth(&floating_width, result.type))
                return self.reject(op, "aarch64 call mixes f32 and f64 ABI banks", BackendError.UnsupportedOperation);
            if (isFloating(result.type)) try self.requireFloatingPolicy(op);
        }
        const base = self.plan.call_save_base orelse unreachable;
        for (call_saved, 0..) |reg, index| {
            try self.emitInstruction(encoding.LoadStoreRegImm.str(reg.encode(), registers.SP.encoded, @intCast(@as(usize, base) + index), .x));
        }
        var integer_index: usize = 0;
        var floating_index: usize = 0;
        for (op.operands.items) |operand| {
            const home = try self.valueHome(op, operand.value);
            const slot = switch (home) {
                .register => |reg| blk: {
                    for (call_saved, 0..) |saved, saved_index| {
                        if (reg == saved) break :blk @as(usize, base) + saved_index;
                    }
                    unreachable;
                },
                .stack => |saved_slot| @as(usize, saved_slot),
                .dead => unreachable,
            };
            if (isFloating(operand.value.type)) {
                try self.emitInstruction(encoding.LoadStoreRegImm.ldr(GPR.x8.encode(), registers.SP.encoded, @intCast(slot), .x));
                try self.emitInstruction(if (isF32(operand.value.type))
                    encoding.FMovGeneral.fmovToFprSingle(floatArgumentRegister(@intCast(floating_index)).encode(), GPR.x8.encode())
                else
                    encoding.FMovGeneral.fmovToFprDouble(floatArgumentRegister(@intCast(floating_index)).encode(), GPR.x8.encode()));
                floating_index += 1;
            } else {
                const target = argumentRegister(@intCast(integer_index));
                try self.emitInstruction(encoding.LoadStoreRegImm.ldr(target.encode(), registers.SP.encoded, @intCast(slot), .x));
                if (borrowedKind(operand.value.type) == null)
                    try self.normalize(target, try scalarIntegerKind(self.diagnose, op, operand.value.type));
                integer_index += 1;
            }
        }
        if (op.results.items.len == 1) _ = try scalarArgumentKind(self.diagnose, op, op.results.items[0].type);
        try self.emitCallPointer(callee);
        if (op.results.items.len == 1) {
            const value = op.getResult(0).?;
            if (isFloating(value.type))
                try self.emitInstruction(if (isF32(value.type))
                    encoding.FMovGeneral.fmovFromFprSingle(GPR.x8.encode(), FPR.v0.encode())
                else
                    encoding.FMovGeneral.fmovFromFprDouble(GPR.x8.encode(), FPR.v0.encode()))
            else {
                try self.normalize(.x0, try scalarIntegerKind(self.diagnose, op, value.type));
                try self.move(.x8, .x0);
            }
        }
        for (call_saved, 0..) |reg, index| {
            try self.emitInstruction(encoding.LoadStoreRegImm.ldr(reg.encode(), registers.SP.encoded, @intCast(@as(usize, base) + index), .x));
        }
        if (op.results.items.len == 1) {
            const result = op.getResult(0).?;
            switch (self.plan.get(result).?) {
                .register => |reg| try self.move(reg, .x8),
                .stack => |slot| try self.emitInstruction(encoding.LoadStoreRegImm.str(GPR.x8.encode(), registers.SP.encoded, @intCast(slot), .x)),
                .dead => {},
            }
        }
    }

    /// LDR literal / BLR / B-over-slot puts the 8-byte resolved address in the same code
    /// image without ever executing pointer bytes. The slot is aligned in the image.
    fn emitCallPointer(self: *Emitter, callee: []const u8) BackendError!void {
        const start = self.code.items.len;
        const slot = std.mem.alignForward(usize, start + 3 * Instruction.size, 8);
        const displacement: i19 = @intCast((slot - start) / Instruction.size);
        try self.emitInstruction(encoding.LoadLiteral.ldrX(GPR.x16.encode(), displacement));
        try self.emitInstruction(encoding.UnconditionalBranchReg.blr(GPR.x16.encode()));
        try self.emitInstruction(encoding.UnconditionalBranchImm.b(@intCast(displacement)));
        while (self.code.items.len < slot) try self.emitInstruction(.{ .raw = 0xd503201f });
        std.debug.assert(self.code.items.len == slot);
        self.code.appendNTimes(self.allocator, 0, 8) catch return BackendError.OutOfMemory;
        self.calls.append(self.allocator, .{ .offset = slot, .target = callee }) catch return BackendError.OutOfMemory;
        std.debug.assert(self.code.items.len == slot + 8);
    }

    fn move(self: *Emitter, target: GPR, source: GPR) BackendError!void {
        if (target != source) try self.emitInstruction(encoding.LogicalShiftedRegister.movReg(target.encode(), source.encode(), .x));
    }

    fn requireFloatingPolicy(self: *Emitter, op: *ir.Operation) BackendError!void {
        if (!op.getContext().arithmetic_policy.permitsFloatingValues())
            return self.reject(op, "aarch64 floating execution requires masked exceptions, default rounding and unobservable environment", BackendError.UnsupportedOperation);
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
    fn legalScalar(self: *Emitter, op: *ir.Operation, operation: ScalarOp, kind: dialects.arith.ScalarKind) BackendError!void {
        if (kind == .bool) switch (operation) {
            .@"and", .@"or", .xor, .not, .cmp, .select, .cast => {},
            else => return self.reject(op, "aarch64 arithmetic requires an integer operand", BackendError.UnsupportedOperation),
        };
        if (operation == .cast) {
            const source = try scalarIntegerKind(self.diagnose, op, op.operands.items[0].value.type);
            if ((source == .bool or kind == .bool) and source != kind) {
                return self.reject(op, "aarch64 cast does not admit integer boolean conversions", BackendError.UnsupportedOperation);
            }
        }
        if (operation == .cmp) {
            const predicate = (ArithDialect.CmpOp{ .op = op }).getPredicate() orelse
                return self.reject(op, "aarch64 comparison requires a predicate", BackendError.UnsupportedOperation);
            const source = try scalarIntegerKind(self.diagnose, op, op.operands.items[0].value.type);
            if (source == .bool and predicate != .eq and predicate != .ne) {
                return self.reject(op, "aarch64 boolean comparison requires eq or ne", BackendError.UnsupportedOperation);
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
            return self.reject(op, "aarch64 scalar effect declaration cannot be collected", BackendError.UnsupportedOperation);
        if (!declaration.complete) return self.reject(op, "aarch64 scalar effect declaration is incomplete", BackendError.UnsupportedOperation);
        const bits = dialects.arith.scalarBitWidth(kind);
        for (declaration.records) |record| switch (record) {
            .requirement => |requirement| switch (requirement.kind) {
                .nonzero => {
                    if (literalInteger(op.operands.items[1].value)) |rhs| {
                        if (dialects.arith.scalar.maskToBits(rhs, bits) == 0) return self.reject(op, "aarch64 DivisionByZero is statically certain", BackendError.UnsupportedOperation);
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
                                return self.reject(op, "aarch64 SignedDivisionOverflow is statically certain", BackendError.UnsupportedOperation);
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
                        if (dialects.arith.scalar.shiftCount(count, bits) == null) return self.reject(op, "aarch64 InvalidShiftAmount is statically certain", BackendError.UnsupportedOperation);
                    }
                    try self.emitInstruction(encoding.AddSubImmediate.cmpImm(GPR.x17.encode(), bits, .x));
                    try self.requireCondition(.lo);
                },
                else => return self.reject(op, "aarch64 scalar requirement is unsupported", BackendError.UnsupportedOperation),
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

    fn reject(self: *Emitter, op: *ir.Operation, message: []const u8, err: BackendError) BackendError {
        self.failed_operation = op;
        if (self.diagnose) return refuse(op, message, err);
        return err;
    }
};

/// Publishes the refused operation's exact name and location in its diagnostic.
fn refuse(op: *ir.Operation, message: []const u8, err: BackendError) BackendError {
    var diagnostic = op.emitError(message);
    defer diagnostic.deinit();
    _ = diagnostic.emit() catch {};
    return err;
}

fn scalarIntegerKind(diagnose: bool, op: *ir.Operation, typ: ir.Type) BackendError!dialects.arith.ScalarKind {
    const name = typ.getDialectTypeName() orelse return scalarRefusal(diagnose, op);
    const kind = dialects.arith.scalarKindFromTypeName(name) orelse return scalarRefusal(diagnose, op);
    return switch (kind) {
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .index, .bool => kind,
        else => scalarRefusal(diagnose, op),
    };
}

fn scalarArgumentKind(diagnose: bool, op: *ir.Operation, typ: ir.Type) BackendError!dialects.arith.ScalarKind {
    if (isF32(typ)) return .f32;
    if (isF64(typ)) return .f64;
    return scalarIntegerKind(diagnose, op, typ);
}

fn isF32(typ: ir.Type) bool {
    return dialects.arith.scalarKindFromTypeName(typ.getDialectTypeName() orelse "") == .f32;
}

fn isFloating(typ: ir.Type) bool {
    return isF32(typ) or isF64(typ);
}

fn sameFloatingWidth(width: *?dialects.arith.ScalarKind, typ: ir.Type) bool {
    if (!isFloating(typ)) return true;
    const current: dialects.arith.ScalarKind = if (isF32(typ)) .f32 else .f64;
    if (width.*) |selected| return selected == current;
    width.* = current;
    return true;
}

fn isF64(typ: ir.Type) bool {
    return dialects.arith.scalarKindFromTypeName(typ.getDialectTypeName() orelse "") == .f64;
}

fn isU64(typ: ir.Type) bool {
    return dialects.arith.scalarKindFromTypeName(typ.getDialectTypeName() orelse "") == .u64;
}

fn isBool(typ: ir.Type) bool {
    return dialects.arith.scalarKindFromTypeName(typ.getDialectTypeName() orelse "") == .bool;
}

fn scalarRefusal(diagnose: bool, op: *ir.Operation) BackendError {
    if (diagnose) return refuse(op, "aarch64 emission requires a scalar integer type", BackendError.UnsupportedOperation);
    return BackendError.UnsupportedOperation;
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

fn floatArgumentRegister(index: u3) FPR {
    return @fromBackingInt(@intCast(index));
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

test "aarch64 backend refuses raw direct calls and retains artifact relocation names" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    const external = try FuncDialect.FuncOp.createDeclaration(&ctx, loc, "artifact_oracle", &.{}, &.{i64_type});
    try module.getBodyBlock().addOperation(external.op);
    const caller = try FuncDialect.FuncOp.create(&ctx, loc, "caller", &.{}, &.{i64_type});
    try module.getBodyBlock().addOperation(caller.op);
    const call = try FuncDialect.CallOp.create(&ctx, loc, "artifact_oracle", &.{}, &.{i64_type});
    try caller.getEntryBlock().addOperation(call.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{call.getResult(0).?});
    try caller.getEntryBlock().addOperation(ret.op);
    var backend = try Backend.init(allocator, &ctx);
    defer backend.deinit();
    try std.testing.expectError(BackendError.UnsupportedOperation, backend.compileFunctionToMachineCode(module.op, "caller"));
    var out = try backend.compileFunctionToArtifact(module.op, "caller");
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 1), out.linkage.relocations.items.len);
    const relocation = out.linkage.relocations.items[0];
    try std.testing.expectEqual(artifact.RelocationKind.call, relocation.kind);
    try std.testing.expectEqualStrings("artifact_oracle", relocation.symbol);
    try std.testing.expectEqual(@as(?u16, 64), relocation.width_bits);
    try std.testing.expectEqual(@as(u64, 0), relocation.offset % 8);
}

test "aarch64 backend refuses recursive and stack-argument direct calls" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    var backend = try Backend.init(allocator, &ctx);
    defer backend.deinit();

    const recursive = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer recursive.op.erase();
    const self = try FuncDialect.FuncOp.create(&ctx, loc, "self", &.{}, &.{i64_type});
    try recursive.getBodyBlock().addOperation(self.op);
    const self_call = try FuncDialect.CallOp.create(&ctx, loc, "self", &.{}, &.{i64_type});
    try self.getEntryBlock().addOperation(self_call.op);
    const self_return = try FuncDialect.ReturnOp.create(&ctx, loc, &.{self_call.getResult(0).?});
    try self.getEntryBlock().addOperation(self_return.op);
    try std.testing.expectError(BackendError.UnsupportedOperation, backend.compileFunctionToArtifact(recursive.op, "self"));

    const stacked = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer stacked.op.erase();
    const nine_types: [9]ir.Type = @splat(i64_type);
    const external = try FuncDialect.FuncOp.createDeclaration(&ctx, loc, "nine", &nine_types, &.{i64_type});
    try stacked.getBodyBlock().addOperation(external.op);
    const entry = try FuncDialect.FuncOp.create(&ctx, loc, "entry", &.{}, &.{i64_type});
    try stacked.getBodyBlock().addOperation(entry.op);
    var operands: [9]*ir.Value = undefined;
    for (&operands, 0..) |*operand, index| {
        const constant = try ArithDialect.ConstantOp.createInt(&ctx, loc, i64_type, @intCast(index));
        try entry.getEntryBlock().addOperation(constant.op);
        operand.* = constant.getResult();
    }
    const nine_call = try FuncDialect.CallOp.create(&ctx, loc, "nine", &operands, &.{i64_type});
    try entry.getEntryBlock().addOperation(nine_call.op);
    const entry_return = try FuncDialect.ReturnOp.create(&ctx, loc, &.{nine_call.getResult(0).?});
    try entry.getEntryBlock().addOperation(entry_return.op);
    try std.testing.expectError(BackendError.UnsupportedOperation, backend.compileFunctionToArtifact(stacked.op, "entry"));
}

test "aarch64 backend refuses qualified call names before emission" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    const caller = try FuncDialect.FuncOp.create(&ctx, loc, "qualified", &.{}, &.{i64_type});
    try module.getBodyBlock().addOperation(caller.op);
    const call = try FuncDialect.CallOp.create(&ctx, loc, "f", &.{}, &.{i64_type});
    try call.op.setAttr("callee", try ctx.getSymbolRefAttr("nested", &.{"f"}));
    try caller.getEntryBlock().addOperation(call.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{call.getResult(0).?});
    try caller.getEntryBlock().addOperation(ret.op);
    var emitter = Emitter.init(allocator);
    defer emitter.deinit();
    emitter.diagnose = false;
    var graph: CallGraph = .{};
    graph.definitions[0] = caller.op;
    graph.names[0] = "qualified";
    graph.count = 1;
    try std.testing.expectError(error.UnsupportedOperation, graph.collect(call.op));
    try std.testing.expectEqual(call.op, graph.failed_call.?);
    try std.testing.expectError(BackendError.UnsupportedOperation, emitter.emitFunction(caller.op));
    try std.testing.expectEqual(call.op, emitter.failed_operation.?);
    try std.testing.expectEqual(@as(usize, 0), emitter.calls.items.len);
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
    try std.testing.expectEqual(@as(i64, 42), result.?);
}

/// Keep execution witnesses behind this seam until aarch64 is an execution target.
fn compileAndRun(
    backend: *Backend,
    module: *ir.Operation,
    entry: []const u8,
    args: []const i64,
) !?i64 {
    return fixture.run(backend, module, entry, args);
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

    fn run(self: *Witness, args: []const i64) !?i64 {
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
            try std.testing.expectEqual(args[lhs] - args[rhs], (try witness.run(&args)).?);
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
            try std.testing.expectEqual(if (add) case.overflow else case.underflow, (try witness.run(&args)).?);
        }
        var identity: Witness = undefined;
        try identity.init(case.kind, 1, 1);
        defer identity.deinit();
        try identity.ret(&.{identity.function.getArgument(0)});
        try std.testing.expectEqual(case.underflow, (try identity.run(&.{-1})).?);
        var constant: Witness = undefined;
        try constant.init(case.kind, 0, 1);
        defer constant.deinit();
        try constant.ret(&.{try constant.constant(-1)});
        try std.testing.expectEqual(case.underflow, (try constant.run(&.{})).?);
    }
}

test "aarch64 native boolean arguments and constants and void results" {
    if (!supports_native_execution) return error.SkipZigTest;
    for ([_]bool{ false, true }) |value| {
        var identity: Witness = undefined;
        try identity.init(.bool, 1, 1);
        defer identity.deinit();
        try identity.ret(&.{identity.function.getArgument(0)});
        try std.testing.expectEqual(@as(i64, @intFromBool(value)), (try identity.run(&.{@intFromBool(value)})).?);
        var constant: Witness = undefined;
        try constant.init(.bool, 0, 1);
        defer constant.deinit();
        var op = try ArithDialect.ConstantOp.createBool(&constant.ctx, .unknown, value);
        try constant.function.getEntryBlock().addOperation(op.op);
        try constant.ret(&.{op.getResult()});
        try std.testing.expectEqual(@as(i64, @intFromBool(value)), (try constant.run(&.{})).?);
    }
    for ([_]usize{ 0, max_arguments }) |count| {
        var witness: Witness = undefined;
        try witness.init(.i64, count, 0);
        defer witness.deinit();
        try witness.ret(&.{});
        const args: [max_arguments]i64 = @splat(42);
        try std.testing.expectEqual(@as(?i64, null), try witness.run(args[0..count]));
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
        try std.testing.expectError(error.ArgumentCountMismatch, witness.run(args[0..count]));
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
        try std.testing.expectEqual(@as(i64, @intCast(count * (count + 1) / 2)), (try pressure.run(&.{})).?);
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
        const argument_kind = try scalarIntegerKind(true, witness.function.op, witness.function.getArgument(index).type);
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
    const kind = try scalarIntegerKind(true, witness.function.op, witness.function.getResultTypes()[0]);
    const descriptor = dialects.arith.scalarDescriptor(kind);
    const bits = descriptor.bit_width;
    const scalar = dialects.arith.scalar;
    const expected = if (descriptor.class == .signed_integer)
        scalar.truncate(raw, bits)
    else
        scalar.unsignedResult(@bitCast(raw), bits);
    try std.testing.expectEqual(expected, (try witness.run(args)).?);
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
    try std.testing.expectEqual(expected, (try witness.run(args)).?);
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
        for ([_]i64{ 0, 1, 19 }) |upper| try std.testing.expectEqual(upper, (try witness.run(&.{ 0, upper })).?);
        try std.testing.expectEqual(@as(i64, 8), (try witness.run(&.{ 8, 3 })).?);
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
    for ([_]i64{ 0, 1, 17 }) |upper| try std.testing.expectEqual(@divTrunc(upper * (upper - 1), 2), (try witness.run(&.{upper})).?);
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
                try std.testing.expectEqual(expected, (try witness.run(&.{upper})).?);
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
                try std.testing.expectEqual(expected, (try witness.run(&.{ 0, upper })).?);
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

test "aarch64 native execution control admits f32 and f64 carry and rejects mismatched edges by name" {
    for ([_]bool{ false, true }) |floating| {
        var witness: Witness = undefined;
        try witness.init(.i64, 0, 1);
        defer witness.deinit();
        const initial = if (floating) value: {
            const typ = try ArithDialect.getScalarType(&witness.ctx, .f32);
            const constant = try ArithDialect.ConstantOp.createFloat(&witness.ctx, .unknown, typ, 1.0);
            try witness.function.getEntryBlock().addOperation(constant.op);
            break :value constant.getResult();
        } else try witness.constant(1);
        const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{initial}, &.{initial.type});
        try witness.function.getEntryBlock().addOperation(loop.op);
        const cond = try blockConstant(&witness, loop.getBeforeBlock(), .bool, 0);
        const forwarded = if (floating) value: {
            const wide = try ArithDialect.getScalarType(&witness.ctx, .f64);
            const constant = try ArithDialect.ConstantOp.createFloat(&witness.ctx, .unknown, wide, 1.0);
            try loop.getBeforeBlock().addOperation(constant.op);
            break :value constant.getResult();
        } else cond;
        try blockCondition(&witness, loop.getBeforeBlock(), cond, &.{forwarded});
        try blockYield(&witness, loop.getAfterBlock(), loop.getAfterBlock().arguments.items);
        try witness.ret(&.{try witness.constant(0)});
        try std.testing.expectError(BackendError.UnsupportedOperation, witness.backend.compileFunctionToMachineCode(witness.module, "witness"));
        try std.testing.expectEqualStrings("scf.while", witness.diagnostic_operation);
    }
    for ([_]dialects.arith.ScalarKind{ .f32, .f64 }) |kind| {
        var witness: Witness = undefined;
        try witness.init(.i64, 0, 1);
        defer witness.deinit();
        const typ = try ArithDialect.getScalarType(&witness.ctx, kind);
        const constant = try ArithDialect.ConstantOp.createFloat(&witness.ctx, .unknown, typ, 1.0);
        try witness.function.getEntryBlock().addOperation(constant.op);
        const loop = try ScfDialect.WhileOp.create(&witness.ctx, .unknown, &.{constant.getResult()}, &.{typ});
        try witness.function.getEntryBlock().addOperation(loop.op);
        const cond = try blockConstant(&witness, loop.getBeforeBlock(), .bool, 0);
        try blockCondition(&witness, loop.getBeforeBlock(), cond, loop.getBeforeBlock().arguments.items);
        try blockYield(&witness, loop.getAfterBlock(), loop.getAfterBlock().arguments.items);
        try witness.ret(&.{try witness.constant(0)});
        const code = try witness.backend.compileFunctionToMachineCode(witness.module, "witness");
        witness.backend.allocator.free(code);
    }
}

test "aarch64 native execution refuses dead unsupported f32 operations and mixed FP widths" {
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    const narrow = try ArithDialect.getScalarType(&ctx, .f32);
    const wide = try ArithDialect.getScalarType(&ctx, .f64);
    const module = try BuiltinDialect.ModuleOp.create(&ctx, .unknown);
    defer module.op.erase();
    const function = try FuncDialect.FuncOp.create(&ctx, .unknown, "dead_f32_sub", &.{ narrow, narrow }, &.{narrow});
    try module.getBodyBlock().addOperation(function.op);
    const subtraction = try ArithDialect.SubOp.create(&ctx, .unknown, function.getArgument(0), function.getArgument(1));
    try function.getEntryBlock().addOperation(subtraction.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, .unknown, &.{function.getArgument(0)});
    try function.getEntryBlock().addOperation(ret.op);
    const mixed = try FuncDialect.FuncOp.create(&ctx, .unknown, "mixed_width", &.{ narrow, wide }, &.{narrow});
    try module.getBodyBlock().addOperation(mixed.op);
    const mixed_ret = try FuncDialect.ReturnOp.create(&ctx, .unknown, &.{mixed.getArgument(0)});
    try mixed.getEntryBlock().addOperation(mixed_ret.op);
    var emitter = Emitter.init(allocator);
    defer emitter.deinit();
    try std.testing.expectError(BackendError.UnsupportedOperation, emitter.emitFunction(function.op));
    try std.testing.expectEqual(subtraction.op, emitter.failed_operation.?);
    emitter.discard();
    try std.testing.expectError(BackendError.UnsupportedOperation, emitter.emitFunction(mixed.op));
    try std.testing.expectEqual(mixed.op, emitter.failed_operation.?);
    emitter.discard();
    const integer = try ArithDialect.getScalarType(&ctx, .i64);
    const dead_float_function = try FuncDialect.FuncOp.create(&ctx, .unknown, "dead_f32_constant", &.{}, &.{integer});
    try module.getBodyBlock().addOperation(dead_float_function.op);
    const dead_constant = try ArithDialect.ConstantOp.createFloat(&ctx, .unknown, narrow, 1.0);
    try dead_float_function.getEntryBlock().addOperation(dead_constant.op);
    const zero = try ArithDialect.ConstantOp.createInt(&ctx, .unknown, integer, 0);
    try dead_float_function.getEntryBlock().addOperation(zero.op);
    const dead_return = try FuncDialect.ReturnOp.create(&ctx, .unknown, &.{zero.getResult()});
    try dead_float_function.getEntryBlock().addOperation(dead_return.op);
    ctx.arithmetic_policy.environment_observable = true;
    try std.testing.expectError(BackendError.UnsupportedOperation, emitter.emitFunction(dead_float_function.op));
    try std.testing.expectEqual(dead_constant.op, emitter.failed_operation.?);
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
            try std.testing.expectEqual(expected, (try witness.run(&.{upper})).?);
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
