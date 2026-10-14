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
const bound_set = @import("../execution/bounds.zig");
const Excess = bound_set.Excess;
const Refused = bound_set.Refused;
const diagnostics = @import("../../root.zig").diagnostics;
const fixture = @import("fixture/run.zig");

const Allocator = std.mem.Allocator;
const BackendError = interface.BackendError;
const ArithDialect = dialects.ArithDialect;
const admission = @import("admission.zig");
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const MemrefDialect = dialects.MemrefDialect;
const memref = dialects.memref;
const GPR = registers.GPR;
const FPR = registers.FPR;
const GPRSize = registers.GPRSize;
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
        try lowerModule(module, null);
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

        var emitter = try Emitter.init(self.allocator);
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
        var emitter = try Emitter.init(self.allocator);
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

/// The same verified scalar admission used by artifact emission and native execution. A
/// non-null `refused` receives the operation refused and, past a bound, its figures.
pub fn lowerModule(module: *ir.Operation, refused: ?*Refused) BackendError!void {
    var located: Refused = .{};
    admitModule(module, &located) catch |err| {
        if (refused) |into| into.* = located;
        return err;
    };
}

fn admitModule(module: *ir.Operation, located: *Refused) BackendError!void {
    var verification: contract.VerificationDiagnostic = .{};
    contract.verifyModuleWithDiagnostic("backend/aarch64/verify", module, &verification) catch |err| {
        if (verification.failure) |failure| located.* = .{ .operation = failure.operation };
        return err;
    };
    _ = module.walk(.{ .order = .pre_order }, located, verifyBorrowedMemory) catch
        return error.UnsupportedOperation;
    var has_call = false;
    _ = module.walk(.{ .order = .pre_order }, &has_call, findCall) catch unreachable;
    if (has_call) try verifyCallGraph(module, located);
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

/// A bounded direct graph is enough to rule out recursive stack growth in this first cut: one
/// module defines at most this many functions, each a bit of a `u64` reachability row.
pub const max_call_functions: usize = 64;
const CallGraph = struct {
    definitions: [max_call_functions]*ir.Operation = undefined,
    names: [max_call_functions][]const u8 = undefined,
    edges: [max_call_functions]u64 = @splat(0),
    count: usize = 0,
    current: usize = 0,
    failed_call: ?*ir.Operation = null,
    /// The bound `failed_call` was refused past, when it was refused past one.
    excess: ?Excess = null,

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
        self.excess = Excess.of(.call_arguments, max_arguments, 0, op.operands.items.len) orelse
            Excess.of(.results, max_results, 0, op.results.items.len);
        if (self.excess != null) {
            self.failed_call = op;
            return error.UnsupportedOperation;
        }
        var floating_width: ?dialects.arith.ScalarKind = null;
        for (op.operands.items) |operand| {
            if (isHostAddress(operand.value.type)) continue;
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

fn verifyCallGraph(module: *ir.Operation, located: *Refused) BackendError!void {
    var graph: CallGraph = .{};
    const block = module.getRegion(0).?.getEntryBlock().?;
    var cursor = block.operations.head;
    while (cursor) |item| {
        const op: *ir.Operation = @ptrCast(@alignCast(item));
        cursor = op.next_op;
        if (!std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) continue;
        const function = FuncDialect.FuncOp{ .op = op };
        if (!function.hasBody()) continue;
        if (Excess.of(.module_functions, max_call_functions, graph.count, 1)) |excess|
            return refuseExcessAt(located, op, excess);
        graph.definitions[graph.count] = op;
        graph.names[graph.count] = function.getName() orelse
            return refuseAt(located, op, "aarch64 direct call function has no name", error.UnsupportedOperation);
        graph.count += 1;
    }
    for (graph.definitions[0..graph.count], 0..) |definition, index| {
        graph.current = index;
        _ = definition.walk(.{ .order = .pre_order }, &graph, CallGraph.collect) catch {
            const refused = graph.failed_call orelse definition;
            const excess = graph.excess orelse
                return refuseAt(located, refused, "aarch64 direct call requires a flat name and scalar register arguments", error.UnsupportedOperation);
            return refuseExcessAt(located, refused, excess);
        };
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
            return refuseAt(located, graph.definitions[index], "aarch64 direct calls require an acyclic graph", error.UnsupportedOperation);
    }
}

const BorrowedKind = enum { byte, word };

/// The boundary signature records only an address word. The IR type, not that erased
/// signature, must establish host storage and the exact layout this emitter understands.
fn borrowedKind(typ: ir.Type) ?BorrowedKind {
    return switch (hostElement(typ) orelse return null) {
        .i8, .u8 => .byte,
        .i64, .u64, .index => .word,
        else => null,
    };
}

/// An atomic access reaches a 32-bit or 64-bit integer element of a default-layout host memref,
/// as memref's verifier admits, through the W or X form of each ordered access.
fn atomicSize(typ: ir.Type) ?GPRSize {
    return switch (hostElement(typ) orelse return null) {
        .i32, .u32 => .w,
        .i64, .u64, .index => .x,
        else => null,
    };
}

/// A memref crossing a call or entry as an address word: one a plain access or an atomic reaches.
fn isHostAddress(typ: ir.Type) bool {
    return borrowedKind(typ) != null or atomicSize(typ) != null;
}

/// The element of a default-layout host memref.
fn hostElement(typ: ir.Type) ?dialects.arith.ScalarKind {
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
    return dialects.arith.scalarKindFromTypeName(params.element_type_name);
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
    if (words == 0) return null;
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
        } else if (std.mem.eql(u8, user.name.name, MemrefDialect.DeallocOp.operation_name)) {
            continue;
        } else if (atomicMemref(user)) |memref_value| {
            if (memref_value == result) continue;
        }
        return false;
    }
    return true;
}

/// What a heap allocation asks malloc for: a static byte size, or a dynamic element count
/// shifted left by the log of its element's bytes.
const Allocation = union(enum) { static_bytes: u64, dynamic_shift: u6 };

/// A heap allocation owns default-layout host bytes or words, sized statically by its type or
/// dynamically by one index count, never both.
fn heapAllocation(op: *ir.Operation) ?Allocation {
    const alloc = MemrefDialect.AllocOp{ .op = op };
    if (op.getNumAttrs() != 0) return null;
    const result = alloc.getResult();
    const shift: u6 = switch (borrowedKind(result.type) orelse return null) {
        .byte => 0,
        .word => 3,
    };
    const params = dialects.memref.paramsOf(result.type) orelse return null;
    if (alloc.getDynamicSize()) |count| {
        if (params.size != null or !isIndex(count.type)) return null;
        return .{ .dynamic_shift = shift };
    }
    const size = params.size orelse return null;
    return .{ .static_bytes = std.math.shlExact(u64, size, shift) catch return null };
}

/// Where a dealloc's memref came from. Only a heap allocation calls free; a stack allocation
/// is released with its frame, so its dealloc emits nothing. Any other memref is refused.
const Release = enum { heap, stack };

fn deallocRelease(op: *ir.Operation) ?Release {
    const memref_value = (MemrefDialect.DeallocOp{ .op = op }).getMemref();
    const raw = memref_value.getDefiningOp() orelse return null;
    const source: *ir.Operation = @ptrCast(@alignCast(raw));
    if (std.mem.eql(u8, source.name.name, MemrefDialect.AllocOp.operation_name))
        return if (heapAllocation(source) != null) .heap else null;
    if (std.mem.eql(u8, source.name.name, MemrefDialect.AllocaOp.operation_name)) return .stack;
    return null;
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
fn verifyBorrowedMemory(located: *Refused, op: *ir.Operation) BackendError!ir.WalkResult {
    if (!std.mem.startsWith(u8, op.name.name, "memref.")) return .advance;
    if (std.mem.eql(u8, op.name.name, MemrefDialect.GlobalOp.operation_name)) {
        if (readOnlyGlobalSymbol(op) == null or !globalNameIsUnique(op))
            return refuseAt(located, op, "aarch64 global requires initialized read-only default-layout host words aligned to a word", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.GetGlobalOp.operation_name)) {
        if (op.getNumAttrs() != 1)
            return refuseAt(located, op, "aarch64 global reference has unsupported attributes", error.UnsupportedOperation);
        const reference = MemrefDialect.GetGlobalOp{ .op = op };
        const name = reference.getSymName() orelse
            return refuseAt(located, op, "aarch64 global reference requires a name", error.UnsupportedOperation);
        const global = memref.findGlobal(op, name) orelse
            return refuseAt(located, op, "aarch64 global reference requires a declared global", error.UnsupportedOperation);
        const typ = global.getType() orelse
            return refuseAt(located, op, "aarch64 global reference requires a declared type", error.UnsupportedOperation);
        if (global.op.getParentOp() != enclosingModule(op) or !globalNameIsUnique(global.op) or
            readOnlyGlobalSymbol(global.op) == null or !reference.getResult().type.eql(typ) or
            !globalUsesAreLoads(reference.getResult()))
            return refuseAt(located, op, "aarch64 global reference requires an exact read-only host word type and only direct loads", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.AllocaOp.operation_name)) {
        const result = (MemrefDialect.AllocaOp{ .op = op }).getResult();
        // A payload wider than the whole frame is refused here, taken whole; one that fits alone
        // but not beside spills or a call frame is refused when placement lays the frame out.
        if (allocaWordCount(op)) |words| {
            const bytes = @as(u64, words) *| @as(u64, placement.slot_bytes);
            if (Excess.of(.frame_bytes, placement.max_frame_bytes, 0, bytes)) |excess|
                return refuseExcessAt(located, op, excess);
        }
        if (allocaWordCount(op) == null or !allocaUsesAreLocal(result))
            return refuseAt(located, op, "aarch64 alloca requires a positive entry-local host word extent with only direct load/store uses", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.AllocOp.operation_name)) {
        if (heapAllocation(op) == null)
            return refuseAt(located, op, "aarch64 alloc requires default-layout host bytes or words sized by its type or by one index count", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.DeallocOp.operation_name)) {
        if (op.getNumAttrs() != 0 or deallocRelease(op) == null)
            return refuseAt(located, op, "aarch64 dealloc requires a memref from this function's alloc or alloca", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.LoadOp.operation_name)) {
        const load = MemrefDialect.LoadOp{ .op = op };
        if (borrowedKind(load.getMemref().type) != .word or !isIndex(load.getIndex().type) or
            !isWordValueOf(load.getResult(), load.getMemref()) or
            op.getAttr("cache") != null or op.getAttr("eviction") != null)
            return refuseAt(located, op, "aarch64 load requires a default-cache host word memref, index and matching word result", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.StoreOp.operation_name)) {
        const store = MemrefDialect.StoreOp{ .op = op };
        if (borrowedKind(store.getMemref().type) != .word or !isIndex(store.getIndex().type) or
            !isWordValueOf(store.getValue(), store.getMemref()) or
            op.getAttr("cache") != null or op.getAttr("eviction") != null)
            return refuseAt(located, op, "aarch64 store requires a default-cache host word memref, index and matching word value", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.ViewOp.operation_name)) {
        const view = MemrefDialect.ViewOp{ .op = op };
        const result = view.getResult();
        const result_params = dialects.memref.paramsOf(result.type) orelse
            return refuseAt(located, op, "aarch64 view requires a static host word result", error.UnsupportedOperation);
        if (borrowedKind(view.getBase().type) != .byte or !isIndex(view.getByteOffset().type) or
            borrowedKind(result.type) != .word or result_params.size == null)
            return refuseAt(located, op, "aarch64 view requires a host byte base, byte offset index and static host word result", error.UnsupportedOperation);
        return .advance;
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.FenceOp.operation_name)) {
        const fence = MemrefDialect.FenceOp{ .op = op };
        if (fence.getScope() == null or fence.getOrdering() == null or op.getNumAttrs() != 2)
            return refuseAt(located, op, "aarch64 fence requires a scope and an ordering", error.UnsupportedOperation);
        return .advance;
    }
    if (atomicMemref(op)) |memref_value| {
        if (!atomicShapeValid(op, memref_value))
            return refuseAt(located, op, "aarch64 atomic requires a 32-bit or 64-bit integer element of a host memref, an index, matching values and an ordering memref admits", error.UnsupportedOperation);
        return .advance;
    }
    return refuseAt(located, op, "aarch64 defers this memory operation", error.UnsupportedOperation);
}

/// The memref an atomic load, store or compare-and-swap reaches, or null for any other operation.
fn atomicMemref(op: *ir.Operation) ?*ir.Value {
    if (std.mem.eql(u8, op.name.name, MemrefDialect.AtomicLoadOp.operation_name)) return (MemrefDialect.AtomicLoadOp{ .op = op }).getMemref();
    if (std.mem.eql(u8, op.name.name, MemrefDialect.AtomicStoreOp.operation_name)) return (MemrefDialect.AtomicStoreOp{ .op = op }).getMemref();
    if (std.mem.eql(u8, op.name.name, MemrefDialect.AtomicCasOp.operation_name)) return (MemrefDialect.AtomicCasOp{ .op = op }).getMemref();
    return null;
}

/// The element and index shapes, value types and orderings memref's verifier states, checked
/// again here because a module can reach the backend unverified.
fn atomicShapeValid(op: *ir.Operation, memref_value: *ir.Value) bool {
    if (atomicSize(memref_value.type) == null) return false;
    if (std.mem.eql(u8, op.name.name, MemrefDialect.AtomicLoadOp.operation_name)) {
        const load = MemrefDialect.AtomicLoadOp{ .op = op };
        const ordering = load.getOrdering() orelse return false;
        return op.getNumAttrs() == 1 and (ordering == .acquire or ordering == .seq_cst) and
            isIndex(load.getIndex().type) and isWordValueOf(load.getResult(), memref_value);
    }
    if (std.mem.eql(u8, op.name.name, MemrefDialect.AtomicStoreOp.operation_name)) {
        const store = MemrefDialect.AtomicStoreOp{ .op = op };
        const ordering = store.getOrdering() orelse return false;
        return op.getNumAttrs() == 1 and (ordering == .release or ordering == .seq_cst) and
            isIndex(store.getIndex().type) and isWordValueOf(store.getValue(), memref_value);
    }
    const cas = MemrefDialect.AtomicCasOp{ .op = op };
    const ordered = op.getAttr("ordering") != null;
    if (ordered) {
        const spelled = op.getAttrAs(ir.Attribute.DialectAttr, "ordering") orelse return false;
        if (memref.FenceOrdering.fromString(spelled.payload) == null) return false;
    }
    return op.getNumAttrs() == @intFromBool(ordered) and isIndex(cas.getIndex().type) and
        isWordValueOf(cas.getExpected(), memref_value) and isWordValueOf(cas.getDesired(), memref_value) and
        isWordValueOf(cas.getResult(), memref_value);
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

/// The f64 and f32 C functions a library operation calls; `single` is null where `sys.math`
/// binds only the f64 function.
pub const LibraryFunction = struct { double: []const u8, single: ?[]const u8 };

/// The names match x64's calls and `sys.math`'s symbols, which the runtime registers.
fn libraryFunction(operation: Emitter.ScalarOp) ?LibraryFunction {
    return switch (operation) {
        inline .exp, .log, .sin, .cos, .tan, .tanh, .pow => |tag| .{
            .double = @tagName(tag),
            .single = @tagName(tag) ++ "f",
        },
        inline .log1p, .expm1 => |tag| .{ .double = @tagName(tag), .single = null },
        else => null,
    };
}

/// Every C function a library operation can call, by its runtime name.
pub const library_symbols = [_][]const u8{
    "exp",   "expf",  "log",  "logf", "sin",   "sinf", "cos",
    "cosf",  "tan",   "tanf", "tanh", "tanhf", "pow",  "powf",
    "log1p", "expm1",
};

/// The C functions heap allocation and release call, which the runtime registers too.
pub const heap_symbols = [_][]const u8{ "malloc", "free" };

/// The Mach-O spelling of a library or heap call's runtime name: the C symbol prefix `_`.
pub fn librarySymbolForObject(name: []const u8) []const u8 {
    inline for (library_symbols ++ heap_symbols) |symbol| {
        if (std.mem.eql(u8, symbol, name)) return "_" ++ symbol;
    }
    unreachable;
}

/// A direct call, a heap allocation or release, or a library operation whose result is read:
/// each needs the call frame. An allocation calls even when unread, since it can fail.
fn callsOut(op: *ir.Operation) bool {
    if (std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name)) return true;
    if (std.mem.eql(u8, op.name.name, MemrefDialect.AllocOp.operation_name)) return true;
    if (std.mem.eql(u8, op.name.name, MemrefDialect.DeallocOp.operation_name))
        return deallocRelease(op) == .heap;
    if (!std.mem.startsWith(u8, op.name.name, "arith.")) return false;
    const operation = std.meta.stringToEnum(Emitter.ScalarOp, op.name.name["arith.".len..]) orelse
        return false;
    if (libraryFunction(operation) == null) return false;
    const value = op.getResult(0) orelse return false;
    return !value.hasNoUses();
}

pub const Emitter = struct {
    allocator: Allocator,
    code: std.ArrayListUnmanaged(u8) = .empty,
    calls: std.ArrayListUnmanaged(machine.CallRelocation) = .empty,
    /// Indices into `calls`, ascending, of the calls library operations, heap allocations and
    /// releases make. An object names these by their C symbols; every other call keeps its IR
    /// name.
    library_calls: std.ArrayListUnmanaged(usize) = .empty,
    data_symbols: machine.DataSymbolSet = .{},
    data_relocations: std.ArrayListUnmanaged(machine.DataRelocation) = .empty,
    /// What `emitFunction` builds each function's placement into. It is the emitter's own, or
    /// one a host lends every emitter that never emits while another does (`initBorrowing`).
    plan: *placement.Plan,
    owns_plan: bool,
    /// Whether values may take register homes, the host's choice, which outlasts the function.
    place_values: bool = true,
    diagnose: bool = true,
    failed_operation: ?*ir.Operation = null,
    /// The bound the current function was refused past, with its figures, set exactly when
    /// `rejectExcess` refused it.
    excess: ?Excess = null,
    first_call_operation: ?*ir.Operation = null,
    first_data_operation: ?*ir.Operation = null,
    active_operation: ?*ir.Operation = null,
    /// The bytes of code reserved before the current function was emitted:
    /// `frame_code_bytes` and `code_bytes_per_operation` for each operation.
    reservation_before_emit: usize = 0,

    /// Bytes of code reserved per operation before a function is emitted. Measured on Apple
    /// M4 over RePPL's church programs, 479 functions emitted at most 26.7 bytes per operation
    /// beyond the frame's 64, so 32 leaves headroom, as x86_64's figure does.
    const code_bytes_per_operation = 32;
    /// Bytes reserved for the frame: the stack adjustment, the frame record and its
    /// link, and the return.
    const frame_code_bytes = 64;
    /// The farthest byte offset `stp` and `ldp` of x registers reach, a signed 7-bit count of
    /// 8-byte words. A frame record past it is addressed through x16, which no value holds at
    /// entry or at the return.
    const pair_reach = 63 * 8;

    /// The frame record's byte offset from sp, just above the registers a call saves. Null for
    /// a function that makes no call.
    fn frameRecord(self: *const Emitter) ?usize {
        const base = self.plan.call_save_base orelse return null;
        const record = (@as(usize, base) + placement.call_save_slots) * placement.slot_bytes;
        std.debug.assert(record + 2 * placement.slot_bytes <= self.plan.frameBytes());
        return record;
    }

    pub fn init(allocator: Allocator) Allocator.Error!Emitter {
        const plan = try allocator.create(placement.Plan);
        plan.* = .{};
        return .{ .allocator = allocator, .plan = plan, .owns_plan = true };
    }

    /// An emitter that builds into `plan`, which outlives it. No two emitters that share a plan
    /// may emit at the same time: each build overwrites the plan whole.
    pub fn initBorrowing(allocator: Allocator, plan: *placement.Plan) Emitter {
        return .{ .allocator = allocator, .plan = plan, .owns_plan = false };
    }

    pub fn deinit(self: *Emitter) void {
        if (self.owns_plan) self.allocator.destroy(self.plan);
        self.code.deinit(self.allocator);
        self.calls.deinit(self.allocator);
        self.library_calls.deinit(self.allocator);
        self.data_symbols.deinit(self.allocator);
        self.data_relocations.deinit(self.allocator);
    }

    /// A retained compiler can emit another function after the runtime has taken its code.
    pub fn discard(self: *Emitter) void {
        self.code.clearRetainingCapacity();
        self.calls.clearRetainingCapacity();
        self.library_calls.clearRetainingCapacity();
        self.data_symbols.clearRetainingCapacity();
        self.data_relocations.clearRetainingCapacity();
        self.plan.reset(null);
        self.failed_operation = null;
        self.excess = null;
        self.first_call_operation = null;
        self.first_data_operation = null;
        self.active_operation = null;
        self.reservation_before_emit = 0;
    }

    /// Emits the verified finite block in order, including unused effects.
    pub fn emitFunction(self: *Emitter, func: *ir.Operation) BackendError!void {
        std.debug.assert(self.code.items.len == 0);
        self.failed_operation = null;
        self.excess = null;
        self.first_call_operation = null;
        self.first_data_operation = null;
        self.active_operation = func;
        self.reservation_before_emit = 0;
        errdefer if (self.failed_operation == null) {
            self.failed_operation = self.active_operation;
        };
        const function = FuncDialect.FuncOp{ .op = func };
        if (!function.hasBody() or function.getBody().blocks.size != 1) {
            return self.reject(func, "aarch64 emission requires a single defined block", BackendError.UnsupportedOperation);
        }
        if (Excess.of(.parameters, max_arguments, 0, function.getNumArguments())) |excess| {
            return self.rejectExcess(func, excess);
        }
        if (Excess.of(.results, max_results, 0, function.getNumResults())) |excess| {
            return self.rejectExcess(func, excess);
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
        self.plan.build(function.getEntryBlock(), self.place_values) catch |err| {
            const message = switch (err) {
                error.ValueCapacity,
                error.FrameCapacity,
                error.OperationCapacity,
                error.CarriedCapacity,
                error.DepthCapacity,
                => return self.rejectExcess(self.plan.refused_operation.?, self.plan.excess.?),
                error.ControlShape => "aarch64 structured control requires matching single-block regions and terminal yield/condition",
                error.ControlType => "aarch64 structured control requires scalar integer or floating values, bool conditions and index induction",
                error.MissingValue => "aarch64 operand has no preceding definition",
            };
            return self.reject(self.plan.refused_operation.?, message, BackendError.UnsupportedOperation);
        };
        for (self.plan.events[0..self.plan.event_count]) |event| {
            if (event.kind != .operation or !callsOut(event.op)) continue;
            self.plan.reserveCallFrame(event.op) catch
                return self.rejectExcess(event.op, self.plan.excess.?);
            break;
        }
        for (self.plan.events[0..self.plan.event_count]) |event| {
            if (event.kind != .operation or !std.mem.eql(u8, event.op.name.name, MemrefDialect.AllocaOp.operation_name)) continue;
            const result = (MemrefDialect.AllocaOp{ .op = event.op }).getResult();
            const words = allocaWordCount(event.op) orelse
                return self.reject(event.op, "aarch64 alloca requires a positive entry-local host word extent", BackendError.UnsupportedOperation);
            self.plan.reserveAlloca(event.op, result, words) catch |err| switch (err) {
                error.FrameCapacity => return self.rejectExcess(event.op, self.plan.excess.?),
                else => return self.reject(event.op, "aarch64 alloca result has no placed value", BackendError.UnsupportedOperation),
            };
        }
        var operations: usize = 0;
        for (self.plan.events[0..self.plan.event_count]) |event| {
            if (event.kind == .operation) operations += 1;
        }
        self.reservation_before_emit = frame_code_bytes + operations * code_bytes_per_operation;
        try self.code.ensureTotalCapacityPrecise(self.allocator, self.reservation_before_emit);
        if (self.plan.frameBytes() != 0) {
            try self.emitInstruction(encoding.AddSubImmediate.sub(registers.SP.encoded, registers.SP.encoded, @intCast(self.plan.frameBytes()), .x));
        }
        if (self.frameRecord()) |record| {
            if (record <= pair_reach) {
                try self.emitInstruction(encoding.LoadStorePair.stpBytes(GPR.x29.encode(), GPR.x30.encode(), registers.SP.encoded, @intCast(record), .x));
                try self.emitInstruction(encoding.AddSubImmediate.add(GPR.x29.encode(), registers.SP.encoded, @intCast(record), .x));
            } else {
                try self.emitInstruction(encoding.AddSubImmediate.add(GPR.x16.encode(), registers.SP.encoded, @intCast(record), .x));
                try self.emitInstruction(encoding.LoadStorePair.stpBytes(GPR.x29.encode(), GPR.x30.encode(), GPR.x16.encode(), 0, .x));
                try self.emitInstruction(encoding.AddSubImmediate.add(GPR.x29.encode(), GPR.x16.encode(), 0, .x));
            }
        }
        // The hardware x and d banks advance independently. First move integer
        // arguments rightward into positional homes, then copy floating bits;
        // (float,i64) must not overwrite physical x0 before x0 is relocated.
        var integer_count: usize = 0;
        for (function.getArguments()) |arg| if (!isFloating(arg.type)) {
            if (!isHostAddress(arg.type)) _ = try scalarIntegerKind(self.diagnose, func, arg.type);
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
            if (!isHostAddress(arg.type))
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
                if (self.frameRecord()) |record| {
                    if (record <= pair_reach) {
                        try self.emitInstruction(encoding.LoadStorePair.ldpBytes(GPR.x29.encode(), GPR.x30.encode(), registers.SP.encoded, @intCast(record), .x));
                    } else {
                        try self.emitInstruction(encoding.AddSubImmediate.add(GPR.x16.encode(), registers.SP.encoded, @intCast(record), .x));
                        try self.emitInstruction(encoding.LoadStorePair.ldpBytes(GPR.x29.encode(), GPR.x30.encode(), GPR.x16.encode(), 0, .x));
                    }
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
        sqrt,
        fma,
        floor,
        exp,
        log,
        log1p,
        expm1,
        sin,
        cos,
        tan,
        tanh,
        pow,
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
        if (std.mem.eql(u8, op.name.name, MemrefDialect.AllocOp.operation_name)) return self.emitAlloc(op);
        if (std.mem.eql(u8, op.name.name, MemrefDialect.DeallocOp.operation_name)) return self.emitDealloc(op);
        if (std.mem.eql(u8, op.name.name, MemrefDialect.FenceOp.operation_name)) return self.emitFence(op);
        if (atomicMemref(op) != null) return self.emitAtomic(op);
        if (std.mem.eql(u8, op.name.name, MemrefDialect.LoadOp.operation_name) or
            std.mem.eql(u8, op.name.name, MemrefDialect.StoreOp.operation_name) or
            std.mem.eql(u8, op.name.name, MemrefDialect.ViewOp.operation_name)) return self.emitBorrowedMemory(op);
        if (overflowKind(op.name.name)) |kind| return self.emitOverflow(op, kind);
        if (std.mem.eql(u8, op.name.name, ArithDialect.SplatOp.operation_name)) return self.emitSplat(op);
        if (std.mem.eql(u8, op.name.name, ArithDialect.ExtractOp.operation_name)) return self.emitExtract(op);
        if (std.mem.eql(u8, op.name.name, ArithDialect.InsertOp.operation_name)) return self.emitInsert(op);
        if (std.mem.eql(u8, op.name.name, ArithDialect.VecCmpOp.operation_name)) return self.emitVecCmp(op);
        if (std.mem.eql(u8, op.name.name, ArithDialect.VecShuffleOp.operation_name)) return self.emitVecShuffle(op);
        if (std.mem.eql(u8, op.name.name, ArithDialect.VecConstantOp.operation_name)) return self.emitVecConstant(op);
        const operation = std.meta.stringToEnum(ScalarOp, op.name.name["arith.".len..]) orelse
            return self.reject(op, "aarch64 emission defers this operation", BackendError.UnsupportedOperation);
        std.debug.assert(op.results.items.len == 1);
        const value = op.getResult(0).?;
        if (placement.isVector(value)) return self.emitVectorLanes(op, operation);
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
            .bitcast => {
                try self.move(target, .x16);
                try self.normalize(target, kind);
            },
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
            .sqrt, .fma, .floor, .exp, .log, .log1p, .expm1, .sin, .cos, .tan, .tanh, .pow => return self.reject(op, "aarch64 sqrt, fma, floor and library functions require f32 or f64", BackendError.UnsupportedOperation),
        }
        try self.normalize(target, kind);
        try self.store(value, target);
    }

    const Overflow = enum { add, sub, mul };

    const overflow_refusal =
        "aarch64 overflow arithmetic requires i64 operands and (i64, bool) results";

    fn overflowKind(name: []const u8) ?Overflow {
        if (std.mem.eql(u8, name, ArithDialect.AddoOp.operation_name)) return .add;
        if (std.mem.eql(u8, name, ArithDialect.SuboOp.operation_name)) return .sub;
        if (std.mem.eql(u8, name, ArithDialect.MuloOp.operation_name)) return .mul;
        return null;
    }

    /// Signed i64 arithmetic with both results: the wrapping value and whether the exact
    /// result leaves i64. ADDS and SUBS set V exactly on signed overflow. A product
    /// overflows exactly when SMULH's high half differs from the low half's sign
    /// extension. Any shape but i64 operands and (i64, bool) results is refused here, since
    /// a caller of `emitFunction` need not have verified the function.
    /// The flags survive the value's move or spill store, so the overflow bit is read last.
    fn emitOverflow(self: *Emitter, op: *ir.Operation, kind: Overflow) BackendError!void {
        if (!overflowShape(op)) {
            return self.reject(op, overflow_refusal, BackendError.UnsupportedOperation);
        }
        const value = op.getResult(0).?;
        const overflow = op.getResult(1).?;
        if (value.hasNoUses() and overflow.hasNoUses()) return;
        const operands = [_]GPR{ .x16, .x17 };
        for (op.operands.items, operands) |operand, temporary| {
            const source = try self.location(op, operand.value, temporary);
            try self.move(temporary, source);
        }
        const lhs = GPR.x16.encode();
        const rhs = GPR.x17.encode();
        const high = GPR.x8.encode();
        const condition: encoding.Condition = switch (kind) {
            .add => blk: {
                try self.emitInstruction(encoding.AddSubShiftedRegister.addsReg(lhs, lhs, rhs, .x));
                break :blk .vs;
            },
            .sub => blk: {
                try self.emitInstruction(encoding.AddSubShiftedRegister.subsReg(lhs, lhs, rhs, .x));
                break :blk .vs;
            },
            .mul => blk: {
                try self.emitInstruction(encoding.DataProcessing3Source.smulh(high, lhs, rhs));
                try self.emitInstruction(encoding.DataProcessing3Source.mul(lhs, lhs, rhs, .x));
                try self.emitInstruction(encoding.AddSubShiftedRegister.cmpShiftedReg(high, lhs, .asr, 63, .x));
                break :blk .ne;
            },
        };
        if (!value.hasNoUses()) {
            const target = self.destination(value);
            try self.move(target, .x16);
            try self.store(value, target);
        }
        if (!overflow.hasNoUses()) {
            const target = self.destination(overflow);
            try self.emitInstruction(encoding.ConditionalSelect.cset(target.encode(), condition, .x));
            try self.store(overflow, target);
        }
    }

    /// Floating live ranges remain raw words in the ordinary placement homes.
    /// Only v16-v18 hold transient operands; no FP register survives a call.
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
        if (operation == .bitcast) return self.emitFloatBitcast(op);
        if (operation == .cast) return self.emitFloatCast(op);
        if (libraryFunction(operation) != null) return self.emitLibraryCall(op, operation);
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
            .add, .sub, .mul, .div, .neg, .abs, .select, .cmp, .sqrt, .fma, .floor => {},
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
            .sqrt, .floor => {
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v16.encode(), GPR.x16.encode()));
                try self.emitInstruction(if (operation == .sqrt)
                    encoding.FP1Source.fsqrt(FPR.v16.encode(), FPR.v16.encode(), .double)
                else
                    encoding.FP1Source.frintm(FPR.v16.encode(), FPR.v16.encode(), .double));
                try self.emitInstruction(encoding.FMovGeneral.fmovFromFprDouble(target.encode(), FPR.v16.encode()));
            },
            .fma => {
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v16.encode(), GPR.x16.encode()));
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v17.encode(), GPR.x17.encode()));
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v18.encode(), GPR.x8.encode()));
                try self.emitInstruction(encoding.FP3Source.fmadd(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), FPR.v18.encode(), .double));
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
                const condition = floatCondition(predicate) orelse
                    return self.reject(op, "aarch64 f64 comparison requires eq/ne/lt/le/gt/ge", BackendError.UnsupportedOperation);
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v16.encode(), GPR.x16.encode()));
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v17.encode(), GPR.x17.encode()));
                try self.emitInstruction(encoding.FPCompare.fcmp(FPR.v16.encode(), FPR.v17.encode(), .double));
                try self.emitInstruction(encoding.ConditionalSelect.cset(target.encode(), condition, .x));
            },
            else => unreachable,
        }
        try self.store(value, target);
    }

    /// A bitcast with a float on either side copies the word between two homes of one width.
    /// An f32 lives as a zero-extended word and an i32 as a sign-extended one, so only that
    /// pair changes the upper half.
    fn emitFloatBitcast(self: *Emitter, op: *ir.Operation) BackendError!void {
        const source = op.operands.items[0].value;
        const value = op.getResult(0).?;
        const from = try scalarArgumentKind(self.diagnose, op, source.type);
        const to = try scalarArgumentKind(self.diagnose, op, value.type);
        if (!bitcastPair(from, to)) return self.reject(op, bitcast_refusal, BackendError.UnsupportedOperation);
        if (value.hasNoUses()) return;
        const register = try self.location(op, source, .x16);
        const target = self.destination(value);
        try self.move(target, register);
        if (from == .i32 and to == .f32) try self.extend(target, 32, false);
        if (from == .f32 and to == .i32) try self.extend(target, 32, true);
        try self.store(value, target);
    }

    /// A cast to a float: FCVT between the two widths, and SCVTF or UCVTF from the whole
    /// normalized integer word, which rounds once to the result's width.
    fn emitFloatCast(self: *Emitter, op: *ir.Operation) BackendError!void {
        const source = op.operands.items[0].value;
        const value = op.getResult(0).?;
        const single = isF32(value.type);
        if (isFloating(source.type)) {
            if (value.hasNoUses()) return;
            const register = try self.location(op, source, .x16);
            const target = self.destination(value);
            if (isF32(source.type) == single) {
                try self.move(target, register);
            } else if (single) {
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v16.encode(), register.encode()));
                try self.emitInstruction(encoding.FP1Source.fcvt(FPR.v16.encode(), FPR.v16.encode(), .double));
                try self.emitInstruction(encoding.FMovGeneral.fmovFromFprSingle(target.encode(), FPR.v16.encode()));
            } else {
                try self.emitInstruction(encoding.FMovGeneral.fmovToFprSingle(FPR.v16.encode(), register.encode()));
                try self.emitInstruction(encoding.FP1Source.fcvt(FPR.v16.encode(), FPR.v16.encode(), .single));
                try self.emitInstruction(encoding.FMovGeneral.fmovFromFprDouble(target.encode(), FPR.v16.encode()));
            }
            try self.store(value, target);
            return;
        }
        const kind = try scalarIntegerKind(self.diagnose, op, source.type);
        if (kind == .bool) return self.reject(op, "aarch64 numeric cast requires an integer source", BackendError.UnsupportedOperation);
        if (value.hasNoUses()) return;
        const register = try self.location(op, source, .x16);
        try self.move(.x16, register);
        try self.normalize(.x16, kind);
        const unsigned = unsignedKind(kind);
        try self.emitInstruction(if (single)
            (if (unsigned)
                encoding.FPConversion.ucvtfSingleFromX(FPR.v16.encode(), GPR.x16.encode())
            else
                encoding.FPConversion.scvtfSingleFromX(FPR.v16.encode(), GPR.x16.encode()))
        else if (unsigned)
            encoding.FPConversion.ucvtfDoubleFromX(FPR.v16.encode(), GPR.x16.encode())
        else
            encoding.FPConversion.scvtfDoubleFromX(FPR.v16.encode(), GPR.x16.encode()));
        const target = self.destination(value);
        try self.emitInstruction(if (single)
            encoding.FMovGeneral.fmovFromFprSingle(target.encode(), FPR.v16.encode())
        else
            encoding.FMovGeneral.fmovFromFprDouble(target.encode(), FPR.v16.encode()));
        try self.store(value, target);
    }

    /// Guard the dialect's finite, truncating representability law before FCVTZ.
    /// The source remains live in d16 while x17/d17 hold each bound. An f32 source is widened
    /// first, which is exact, so one pair of f64 bounds decides both widths.
    fn emitFloatToInt(self: *Emitter, op: *ir.Operation) BackendError!void {
        const source = op.operands.items[0].value;
        const value = op.getResult(0).?;
        const single = isF32(source.type);
        if (!single and !isF64(source.type)) return self.reject(op, "aarch64 float-to-integer cast requires f32 or f64", BackendError.UnsupportedOperation);
        const kind = try scalarIntegerKind(self.diagnose, op, value.type);
        if (kind == .bool) return self.reject(op, "aarch64 float-to-integer cast requires an integer result", BackendError.UnsupportedOperation);
        const bits = dialects.arith.scalarBitWidth(kind);
        const unsigned = unsignedKind(kind);
        if (source.getDefiningOp()) |raw| {
            const definition: *ir.Operation = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, definition.name.name, ArithDialect.ConstantOp.operation_name)) {
                if ((ArithDialect.ConstantOp{ .op = definition }).getFloatValue()) |declared| {
                    const number: f64 = if (single) @as(f32, @floatCast(declared)) else declared;
                    if (dialects.arith.scalar.floatToInt(number, bits, !unsigned) == null)
                        return self.reject(op, "aarch64 InvalidFloatToInteger is statically certain", BackendError.UnsupportedOperation);
                }
            }
        }

        const register = try self.location(op, source, .x16);
        try self.move(.x16, register);
        if (single) {
            try self.emitInstruction(encoding.FMovGeneral.fmovToFprSingle(FPR.v16.encode(), GPR.x16.encode()));
            try self.emitInstruction(encoding.FP1Source.fcvt(FPR.v16.encode(), FPR.v16.encode(), .single));
        } else {
            try self.emitInstruction(encoding.FMovGeneral.fmovToFprDouble(FPR.v16.encode(), GPR.x16.encode()));
        }
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
        switch (operation) {
            .add, .mul, .div, .cmp, .sqrt, .fma, .floor => {},
            else => return self.reject(op, "aarch64 defers this f32 operation", BackendError.UnsupportedOperation),
        }
        if (operation == .cmp and !isBool(value.type))
            return self.reject(op, "aarch64 f32 comparison requires a boolean result", BackendError.UnsupportedOperation);
        if (operation != .cmp and !isF32(value.type))
            return self.reject(op, "aarch64 f32 operation requires an f32 result", BackendError.UnsupportedOperation);
        for (op.operands.items) |operand| if (!isF32(operand.value.type))
            return self.reject(op, "aarch64 f32 operation requires f32 operands", BackendError.UnsupportedOperation);
        const condition: encoding.Condition = if (operation == .cmp) condition: {
            const predicate = (ArithDialect.CmpOp{ .op = op }).getPredicate() orelse
                return self.reject(op, "aarch64 f32 comparison requires a predicate", BackendError.UnsupportedOperation);
            break :condition floatCondition(predicate) orelse
                return self.reject(op, "aarch64 f32 comparison requires eq/ne/lt/le/gt/ge", BackendError.UnsupportedOperation);
        } else .eq;
        const scratch = [_]GPR{ .x16, .x17, .x8 };
        const transient = [_]FPR{ .v16, .v17, .v18 };
        std.debug.assert(op.operands.items.len <= scratch.len);
        for (op.operands.items, 0..) |operand, index| {
            const source = try self.location(op, operand.value, scratch[index]);
            try self.move(scratch[index], source);
        }
        if (value.hasNoUses()) return;
        const target = self.destination(value);
        for (op.operands.items, 0..) |_, index| {
            try self.emitInstruction(encoding.FMovGeneral.fmovToFprSingle(transient[index].encode(), scratch[index].encode()));
        }
        switch (operation) {
            .add => try self.emitInstruction(encoding.FP2Source.fadd(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), .single)),
            .mul => try self.emitInstruction(encoding.FP2Source.fmul(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), .single)),
            .div => try self.emitInstruction(encoding.FP2Source.fdiv(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), .single)),
            .sqrt => try self.emitInstruction(encoding.FP1Source.fsqrt(FPR.v16.encode(), FPR.v16.encode(), .single)),
            .floor => try self.emitInstruction(encoding.FP1Source.frintm(FPR.v16.encode(), FPR.v16.encode(), .single)),
            .fma => try self.emitInstruction(encoding.FP3Source.fmadd(FPR.v16.encode(), FPR.v16.encode(), FPR.v17.encode(), FPR.v18.encode(), .single)),
            .cmp => {
                try self.emitInstruction(encoding.FPCompare.fcmp(FPR.v16.encode(), FPR.v17.encode(), .single));
                try self.emitInstruction(encoding.ConditionalSelect.cset(target.encode(), condition, .x));
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
        var located: Refused = .{};
        _ = verifyBorrowedMemory(&located, op) catch return BackendError.UnsupportedOperation;
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

    /// x16 holds the element's address, formed first because the ordered accesses take a base
    /// register alone. x17 and x8 carry values. None of the three is ever a home, so an atomic
    /// clobbers no live value, and the emitter keeps program order, so no placement rule is needed.
    /// Every access is emitted even when its result is unread, because its ordering is an effect.
    /// LDAR and STLR are RCsc, so acquire and seq_cst loads share LDAR and release and seq_cst
    /// stores share STLR. Every compare-and-swap is CASAL, as x64's LOCK CMPXCHG is a full
    /// barrier whatever its ordering. CASAL leaves the observed value in x17, which is the result.
    fn emitAtomic(self: *Emitter, op: *ir.Operation) BackendError!void {
        var located: Refused = .{};
        _ = verifyBorrowedMemory(&located, op) catch return BackendError.UnsupportedOperation;
        const memref_value = atomicMemref(op).?;
        const size = atomicSize(memref_value.type).?;
        const element = hostElement(memref_value.type).?;
        const index_value = op.operands.items[op.operands.items.len - 1].value;
        std.debug.assert(op.operands.items[op.operands.items.len - 2].value == memref_value);
        const base = try self.location(op, memref_value, .x16);
        try self.move(.x16, base);
        const index = try self.location(op, index_value, .x17);
        try self.move(.x17, index);
        try self.emitInstruction(encoding.AddSubShiftedRegister.addShiftedReg(GPR.x16.encode(), GPR.x16.encode(), GPR.x17.encode(), .lsl, if (size == .x) 3 else 2, .x));
        if (std.mem.eql(u8, op.name.name, MemrefDialect.AtomicStoreOp.operation_name)) {
            const value = try self.location(op, (MemrefDialect.AtomicStoreOp{ .op = op }).getValue(), .x8);
            try self.move(.x8, value);
            try self.emitInstruction(encoding.LoadStoreOrdered.stlr(GPR.x8.encode(), GPR.x16.encode(), size));
            return;
        }
        const observed: GPR = if (std.mem.eql(u8, op.name.name, MemrefDialect.AtomicLoadOp.operation_name)) load: {
            try self.emitInstruction(encoding.LoadStoreOrdered.ldar(GPR.x17.encode(), GPR.x16.encode(), size));
            break :load .x17;
        } else cas: {
            const cas = MemrefDialect.AtomicCasOp{ .op = op };
            const expected = try self.location(op, cas.getExpected(), .x17);
            try self.move(.x17, expected);
            const desired = try self.location(op, cas.getDesired(), .x8);
            try self.move(.x8, desired);
            try self.emitInstruction(encoding.LoadStoreOrdered.casal(GPR.x17.encode(), GPR.x8.encode(), GPR.x16.encode(), size));
            break :cas .x17;
        };
        const result = op.getResult(0).?;
        if (result.hasNoUses()) return;
        const target = self.destination(result);
        try self.move(target, observed);
        try self.normalize(target, element);
        try self.store(result, target);
    }

    /// x64 emits code only for a seq_cst fence, since TSO gives it the rest; aarch64 needs a
    /// barrier for each. Every scope orders the CPU threads of one process, the inner-shareable
    /// domain, as LLVM lowers its default system scope; no scope claims anything about devices.
    fn emitFence(self: *Emitter, op: *ir.Operation) BackendError!void {
        var located: Refused = .{};
        _ = verifyBorrowedMemory(&located, op) catch return BackendError.UnsupportedOperation;
        const ordering = (MemrefDialect.FenceOp{ .op = op }).getOrdering().?;
        try self.emitInstruction(encoding.Barrier.dmb(if (ordering == .acquire) .ishld else .ish));
    }

    /// LDR literal / B-over-slot leaves one aligned eight-byte address for
    /// Runtime's checked data relocation. No instruction executes the slot.
    fn emitGlobalAddress(self: *Emitter, op: *ir.Operation) BackendError!void {
        var located: Refused = .{};
        _ = verifyBorrowedMemory(&located, op) catch return BackendError.UnsupportedOperation;
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

    /// The admitted shape of a vector type. Any other vector type is refused here by name.
    fn vectorShape(self: *Emitter, op: *ir.Operation, typ: ir.Type) BackendError!admission.VectorShape {
        const name = typ.getDialectTypeName() orelse
            return self.reject(op, "aarch64 vector operation requires a vector type", BackendError.UnsupportedOperation);
        const shape = admission.vectorShape(name) orelse
            return self.reject(op, "aarch64 admits only vectors of 2 x f32, i32, u32, f64, i64, u64 or 4 x f32, i32, u32, i16, u16", BackendError.UnsupportedOperation);
        if (dialects.arith.scalarKindIsFloat(shape.lane)) try self.requireFloatingPolicy(op);
        return shape;
    }

    /// LDR Q from the value's two-slot frame home. A vector never has a register home.
    fn loadVector(self: *Emitter, op: *ir.Operation, value: *ir.Value, register: FPR) BackendError!void {
        const slot = switch (try self.valueHome(op, value)) {
            .stack => |slot| slot,
            .register, .dead => unreachable,
        };
        std.debug.assert(slot % placement.vector_slots == 0 and slot + 1 < self.plan.frame_slots);
        try self.emitInstruction(encoding.LoadStoreRegImmFP.ldrQ(register.encode(), registers.SP.encoded, @intCast(slot / placement.vector_slots)));
    }

    fn storeVector(self: *Emitter, value: *ir.Value, register: FPR) BackendError!void {
        const slot = switch (self.plan.get(value).?) {
            .stack => |slot| slot,
            .dead => return,
            .register => unreachable,
        };
        std.debug.assert(slot % placement.vector_slots == 0 and slot + 1 < self.plan.frame_slots);
        try self.emitInstruction(encoding.LoadStoreRegImmFP.strQ(register.encode(), registers.SP.encoded, @intCast(slot / placement.vector_slots)));
    }

    /// The scalar a lane operation reads or writes has the lane's own type.
    fn requireLane(self: *Emitter, op: *ir.Operation, shape: admission.VectorShape, typ: ir.Type) BackendError!void {
        const name = typ.getDialectTypeName() orelse "";
        if (dialects.arith.scalarKindFromTypeName(name) != shape.lane)
            return self.reject(op, "aarch64 lane operation requires a scalar of the vector's lane type", BackendError.UnsupportedOperation);
    }

    fn laneIndex(self: *Emitter, op: *ir.Operation, index: ?i64, shape: admission.VectorShape) BackendError!u3 {
        const lane = index orelse return self.reject(op, "aarch64 lane operation requires a lane index", BackendError.UnsupportedOperation);
        if (lane < 0 or lane >= shape.arrangement.lanes())
            return self.reject(op, "aarch64 lane index is outside the vector", BackendError.UnsupportedOperation);
        return @intCast(lane);
    }

    /// DUP copies the scalar's home bits to every lane; a floating scalar's home already holds
    /// its bits. A 64-bit arrangement zeroes the register's high half, which every vector keeps.
    fn emitSplat(self: *Emitter, op: *ir.Operation) BackendError!void {
        const result = op.getResult(0).?;
        const shape = try self.vectorShape(op, result.type);
        const scalar = op.operands.items[0].value;
        try self.requireLane(op, shape, scalar.type);
        if (result.hasNoUses()) return;
        const source = try self.location(op, scalar, .x16);
        try self.emitInstruction(encoding.SimdCopy.dup(FPR.v16.encode(), source.encode(), shape.arrangement));
        try self.storeVector(result, .v16);
    }

    /// UMOV zero-extends the lane; a narrow signed lane is then sign-extended like any
    /// definition of its type.
    fn emitExtract(self: *Emitter, op: *ir.Operation) BackendError!void {
        const extract = ArithDialect.ExtractOp{ .op = op };
        const vector = extract.getVector();
        const shape = try self.vectorShape(op, vector.type);
        const result = extract.getResult();
        try self.requireLane(op, shape, result.type);
        const lane = try self.laneIndex(op, extract.getIndex(), shape);
        if (result.hasNoUses()) return;
        try self.loadVector(op, vector, .v16);
        const target = self.destination(result);
        try self.emitInstruction(encoding.SimdCopy.umov(target.encode(), FPR.v16.encode(), shape.arrangement, lane));
        if (!dialects.arith.scalarKindIsFloat(shape.lane)) try self.normalize(target, shape.lane);
        try self.store(result, target);
    }

    /// INS replaces one lane of a copy; the operand vector keeps its own home.
    fn emitInsert(self: *Emitter, op: *ir.Operation) BackendError!void {
        const insert = ArithDialect.InsertOp{ .op = op };
        const result = insert.getResult();
        const shape = try self.vectorShape(op, result.type);
        if (!insert.getVector().type.eql(result.type))
            return self.reject(op, "aarch64 insert requires its vector and result to share a type", BackendError.UnsupportedOperation);
        try self.requireLane(op, shape, insert.getScalar().type);
        const lane = try self.laneIndex(op, insert.getIndex(), shape);
        if (result.hasNoUses()) return;
        try self.loadVector(op, insert.getVector(), .v16);
        const source = try self.location(op, insert.getScalar(), .x16);
        try self.emitInstruction(encoding.SimdCopy.ins(FPR.v16.encode(), source.encode(), shape.arrangement, lane));
        try self.storeVector(result, .v16);
    }

    /// Admission follows the dialect's declaration, which arith completes for a comparison,
    /// shuffle or constant only when its shapes, predicate, indices or attribute are valid.
    /// None can fail.
    fn requireVectorDeclaration(self: *Emitter, op: *ir.Operation) BackendError!void {
        const facts = ir.interfaces.effects;
        var storage: [max_scalar_facts]facts.Fact = undefined;
        const declaration = facts.collectInto(op, &storage) catch
            return self.reject(op, "aarch64 vector effect declaration cannot be collected", BackendError.UnsupportedOperation);
        if (!declaration.complete)
            return self.reject(op, "aarch64 vector operation requires the shapes, predicate, indices or attribute arith declares valid", BackendError.UnsupportedOperation);
        for (declaration.records) |record| switch (record) {
            .premise => |premise| if (premise != .floating_environment)
                return self.reject(op, "aarch64 vector operation requires the default floating environment", BackendError.UnsupportedOperation),
            .requirement, .event => return self.reject(op, "aarch64 vector operation has unsupported effects", BackendError.UnsupportedOperation),
            else => {},
        };
    }

    /// Each mask lane holds 0 or 1, as x64 leaves it, whether the mask's lanes are integers or
    /// the operands' own type. Every float predicate but ne is ordered, so a NaN in either
    /// operand gives 0 and ne gives 1. Integer signedness comes from the predicate, as in the
    /// scalar comparison. CM* and FCM* leave all ones or zero, and USHR keeps the low bit.
    fn emitVecCmp(self: *Emitter, op: *ir.Operation) BackendError!void {
        const compare = ArithDialect.VecCmpOp{ .op = op };
        const lhs = op.operands.items[0].value;
        const rhs = op.operands.items[1].value;
        const result = compare.getResult();
        const shape = try self.vectorShape(op, lhs.type);
        const mask = try self.vectorShape(op, result.type);
        try self.requireVectorDeclaration(op);
        std.debug.assert(rhs.type.eql(lhs.type) and mask.arrangement == shape.arrangement);
        const predicate = compare.getPredicate().?;
        if (result.hasNoUses()) return;

        const floating = dialects.arith.scalarKindIsFloat(shape.lane);
        const Plan = struct { compare: encoding.SimdThreeSame.Operation, swap: bool = false, invert: bool = false };
        const plan: Plan = switch (predicate) {
            .eq => .{ .compare = if (floating) .fcmeq else .cmeq },
            .ne => .{ .compare = if (floating) .fcmeq else .cmeq, .invert = true },
            .gt, .sgt => .{ .compare = if (floating) .fcmgt else .cmgt },
            .ge, .sge => .{ .compare = if (floating) .fcmge else .cmge },
            .lt, .slt => .{ .compare = if (floating) .fcmgt else .cmgt, .swap = true },
            .le, .sle => .{ .compare = if (floating) .fcmge else .cmge, .swap = true },
            .ugt => .{ .compare = .cmhi },
            .uge => .{ .compare = .cmhs },
            .ult => .{ .compare = .cmhi, .swap = true },
            .ule => .{ .compare = .cmhs, .swap = true },
        };
        std.debug.assert(!floating or switch (plan.compare) {
            .fcmeq, .fcmge, .fcmgt => true,
            else => false,
        });
        try self.loadVector(op, lhs, .v16);
        try self.loadVector(op, rhs, .v17);
        const v16 = FPR.v16.encode();
        const v17 = FPR.v17.encode();
        const v18 = FPR.v18.encode();
        const first, const second = if (plan.swap) .{ v17, v16 } else .{ v16, v17 };
        try self.emitInstruction(encoding.SimdThreeSame.of(plan.compare, v18, first, second, shape.arrangement));
        if (plan.invert) try self.emitInstruction(encoding.SimdTwoRegisterMisc.of(.not, v18, v18, shape.arrangement));
        try self.emitInstruction(encoding.SimdShiftImmediate.ushr(v18, v18, shape.arrangement, shape.arrangement.laneBits() - 1));
        try self.storeVector(result, .v18);
    }

    /// The one attribute fills every lane: an integer truncated to the lane's width, as x64 masks
    /// it, and a float converted to f32 lanes as x64 converts it, rounding to nearest. x16 holds
    /// the lane bits only within this operation and never crosses a call sequence.
    fn emitVecConstant(self: *Emitter, op: *ir.Operation) BackendError!void {
        const constant = ArithDialect.VecConstantOp{ .op = op };
        const result = constant.getResult();
        const shape = try self.vectorShape(op, result.type);
        try self.requireVectorDeclaration(op);
        if (result.hasNoUses()) return;
        const bits: u64 = if (constant.getIntValue()) |integer| @bitCast(integer) else float: {
            const number = constant.getFloatValue().?;
            if (shape.lane == .f32) break :float @as(u32, @bitCast(@as(f32, @floatCast(number))));
            break :float @bitCast(number);
        };
        try self.emitMoveImmediate(.x16, bits);
        try self.emitInstruction(encoding.SimdCopy.dup(FPR.v16.encode(), GPR.x16.encode(), shape.arrangement));
        try self.storeVector(result, .v16);
    }

    /// One INS per result lane from the source lane its index names. A 64-bit result starts
    /// from zero, so its high half stays zero as every vector's does.
    fn emitVecShuffle(self: *Emitter, op: *ir.Operation) BackendError!void {
        const shuffle = ArithDialect.VecShuffleOp{ .op = op };
        const source = shuffle.getVector();
        const result = shuffle.getResult();
        const from = try self.vectorShape(op, source.type);
        const to = try self.vectorShape(op, result.type);
        try self.requireVectorDeclaration(op);
        var buffer: [4]i64 = undefined;
        const indices = shuffle.getIndices(&buffer) catch
            return self.reject(op, "aarch64 shuffle requires one index per result lane", BackendError.UnsupportedOperation);
        std.debug.assert(indices.len == to.arrangement.lanes() and from.lane == to.lane);
        if (result.hasNoUses()) return;

        const v16 = FPR.v16.encode();
        const v17 = FPR.v17.encode();
        try self.loadVector(op, source, .v16);
        if (!to.arrangement.full()) try self.emitInstruction(encoding.SimdThreeSame.of(.eor, v17, v17, v17, .@"2d"));
        for (indices, 0..) |index, lane| {
            std.debug.assert(index >= 0 and index < from.arrangement.lanes());
            try self.emitInstruction(encoding.SimdCopy.insElement(v17, v16, to.arrangement, @intCast(lane), @intCast(index)));
        }
        try self.storeVector(result, .v17);
    }

    /// One operation on every lane of vectors of one admitted type, each lane computed as the
    /// scalar operation computes it. Only operations no lane can fail are lowered. Integer
    /// division and remainder and the shifts wait on arith to say what a failing lane does;
    /// floating min and max wait on it to define NaN and signed-zero results.
    fn emitVectorLanes(self: *Emitter, op: *ir.Operation, operation: ScalarOp) BackendError!void {
        const result = op.getResult(0).?;
        const shape = try self.vectorShape(op, result.type);
        const floating = dialects.arith.scalarKindIsFloat(shape.lane);
        switch (operation) {
            .add, .sub, .mul, .neg, .select => {},
            .div => if (!floating)
                return self.reject(op, "aarch64 vectors defer integer division, remainder and shifts until arith defines a failing lane", BackendError.UnsupportedOperation),
            .min, .max => if (floating)
                return self.reject(op, "aarch64 vectors defer floating min and max until arith defines their NaN and signed-zero results", BackendError.UnsupportedOperation),
            .@"and", .@"or", .xor, .not => if (floating)
                return self.reject(op, "aarch64 bitwise vector operations require integer lanes", BackendError.UnsupportedOperation),
            .rem, .shl, .shr, .ushr => return self.reject(op, "aarch64 vectors defer integer division, remainder and shifts until arith defines a failing lane", BackendError.UnsupportedOperation),
            .umulhi, .popcount => return self.reject(op, "aarch64 vectors defer umulhi and popcount", BackendError.UnsupportedOperation),
            else => return self.reject(op, "aarch64 has no vector form of this operation", BackendError.UnsupportedOperation),
        }
        const lanes = if (operation == .select) op.operands.items[1..] else op.operands.items;
        for (lanes) |operand| if (!operand.value.type.eql(result.type))
            return self.reject(op, "aarch64 vector operation requires its operands and result to share a type", BackendError.UnsupportedOperation);
        if (operation == .select and !isBool(op.operands.items[0].value.type))
            return self.reject(op, "aarch64 vector select requires a scalar bool choosing a whole vector", BackendError.UnsupportedOperation);
        if (result.hasNoUses()) return;

        const arrangement = shape.arrangement;
        const v16 = FPR.v16.encode();
        const v17 = FPR.v17.encode();
        const v18 = FPR.v18.encode();
        switch (operation) {
            .neg, .not => {
                try self.loadVector(op, op.operands.items[0].value, .v16);
                const misc: encoding.SimdTwoRegisterMisc.Operation = if (operation == .not) .not else if (floating) .fneg else .neg;
                try self.emitInstruction(encoding.SimdTwoRegisterMisc.of(misc, v16, v16, arrangement));
                return self.storeVector(result, .v16);
            },
            .select => {
                // A true condition becomes an all-ones mask in every lane, and BSL takes
                // the true vector's bits under it and the false vector's elsewhere.
                const condition = try self.location(op, op.operands.items[0].value, .x16);
                try self.emitInstruction(encoding.AddSubImmediate.cmpImm(condition.encode(), 0, .x));
                try self.emitInstruction(encoding.ConditionalSelect.csetm(GPR.x16.encode(), .ne, .x));
                try self.emitInstruction(encoding.SimdCopy.dup(v18, GPR.x16.encode(), .@"2d"));
                try self.loadVector(op, op.operands.items[1].value, .v16);
                try self.loadVector(op, op.operands.items[2].value, .v17);
                try self.emitInstruction(encoding.SimdThreeSame.of(.bsl, v18, v16, v17, arrangement));
                return self.storeVector(result, .v18);
            },
            else => {},
        }
        try self.loadVector(op, op.operands.items[0].value, .v16);
        try self.loadVector(op, op.operands.items[1].value, .v17);
        const lane: encoding.SimdThreeSame.Operation = switch (operation) {
            .add => if (floating) .fadd else .add,
            .sub => if (floating) .fsub else .sub,
            .div => .fdiv,
            .@"and" => .@"and",
            .@"or" => .orr,
            .xor => .eor,
            .mul => if (floating) .fmul else if (arrangement.laneBits() == 64) {
                // NEON has no 64-bit lane multiply; each lane multiplies through x16 and x17.
                for (0..arrangement.lanes()) |index| {
                    const at: u3 = @intCast(index);
                    try self.emitInstruction(encoding.SimdCopy.umov(GPR.x16.encode(), v16, arrangement, at));
                    try self.emitInstruction(encoding.SimdCopy.umov(GPR.x17.encode(), v17, arrangement, at));
                    try self.emitInstruction(encoding.DataProcessing3Source.mul(GPR.x16.encode(), GPR.x16.encode(), GPR.x17.encode(), .x));
                    try self.emitInstruction(encoding.SimdCopy.ins(v16, GPR.x16.encode(), arrangement, at));
                }
                return self.storeVector(result, .v16);
            } else .mul,
            .min, .max => {
                // v18 marks the lanes where lhs exceeds rhs; max takes lhs there, min rhs.
                const greater: encoding.SimdThreeSame.Operation = if (unsignedKind(shape.lane)) .cmhi else .cmgt;
                try self.emitInstruction(encoding.SimdThreeSame.of(greater, v18, v16, v17, arrangement));
                const taken, const other = if (operation == .max) .{ v16, v17 } else .{ v17, v16 };
                try self.emitInstruction(encoding.SimdThreeSame.of(.bsl, v18, taken, other, arrangement));
                return self.storeVector(result, .v18);
            },
            else => unreachable,
        };
        try self.emitInstruction(encoding.SimdThreeSame.of(lane, v16, v16, v17, arrangement));
        try self.storeVector(result, .v16);
    }

    const call_saved = [placement.call_save_slots]GPR{
        .x0, .x1,  .x2,  .x3,  .x4,  .x5,  .x6,  .x7,
        .x9, .x10, .x11, .x12, .x13, .x14, .x15,
    };

    /// Every source is read from its saved pre-call home, so argument permutations cannot
    /// destroy one another. x8 holds the returned word while old caller state is restored.
    fn emitCall(self: *Emitter, op: *ir.Operation) BackendError!void {
        const call = FuncDialect.CallOp{ .op = op };
        const reference = call.getCalleeRef() orelse return self.reject(op, "aarch64 call requires a direct callee", BackendError.UnsupportedOperation);
        if (!reference.isFlat()) return self.reject(op, "aarch64 call requires a flat direct callee", BackendError.UnsupportedOperation);
        return self.emitCallTo(op, reference.getRootReference(), .operands);
    }

    /// How a call's arguments and result come from its operation.
    const CallShape = union(enum) {
        /// The operands are the arguments; the one result, if any, is the returned value.
        operands,
        /// The one argument is the allocation's byte size; the result is malloc's address,
        /// and a null address traps as the allocation's failure event.
        allocation: Allocation,
    };

    /// Calls malloc for the bytes the type or count asks for, even when the result is unread.
    fn emitAlloc(self: *Emitter, op: *ir.Operation) BackendError!void {
        const allocation = heapAllocation(op) orelse
            return self.reject(op, "aarch64 alloc requires default-layout host bytes or words", BackendError.UnsupportedOperation);
        try self.emitRuntimeCall(op, "malloc", .{ .allocation = allocation });
    }

    /// Frees a heap allocation; a stack allocation needs nothing.
    fn emitDealloc(self: *Emitter, op: *ir.Operation) BackendError!void {
        const release = deallocRelease(op) orelse
            return self.reject(op, "aarch64 dealloc requires a memref from alloc or alloca", BackendError.UnsupportedOperation);
        if (release == .stack) return;
        try self.emitRuntimeCall(op, "free", .operands);
    }

    /// A call to a C function the runtime registers, which an object names by its C symbol.
    fn emitRuntimeCall(self: *Emitter, op: *ir.Operation, callee: []const u8, shape: CallShape) BackendError!void {
        const index = self.calls.items.len;
        try self.emitCallTo(op, callee, shape);
        std.debug.assert(self.calls.items.len == index + 1);
        self.library_calls.append(self.allocator, index) catch return BackendError.OutOfMemory;
    }

    /// Calls `callee` with arguments and a result `shape` takes from `op`. A library operation
    /// and a heap allocation call through here exactly as a direct call does.
    fn emitCallTo(self: *Emitter, op: *ir.Operation, callee: []const u8, shape: CallShape) BackendError!void {
        if (self.first_call_operation == null) self.first_call_operation = op;
        if (Excess.of(.call_arguments, max_arguments, 0, op.operands.items.len)) |excess|
            return self.rejectExcess(op, excess);
        if (Excess.of(.results, max_results, 0, op.results.items.len)) |excess|
            return self.rejectExcess(op, excess);
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
        switch (shape) {
            .operands => try self.loadCallArguments(op, base),
            .allocation => |allocation| try self.loadAllocationSize(op, base, allocation),
        }
        if (shape == .operands and op.results.items.len == 1)
            _ = try scalarArgumentKind(self.diagnose, op, op.results.items[0].type);
        try self.emitCallPointer(callee);
        if (shape == .allocation) {
            std.debug.assert(op.results.items.len == 1);
            try self.emitInstruction(encoding.AddSubImmediate.cmpImm(GPR.x0.encode(), 0, .x));
            try self.requireCondition(.ne);
            try self.move(.x8, .x0);
        } else if (op.results.items.len == 1) {
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

    /// The pre-call slot `value` was saved to, whether its home is a register or the frame.
    fn savedSlot(self: *Emitter, op: *ir.Operation, value: *ir.Value, base: u16) BackendError!usize {
        return switch (try self.valueHome(op, value)) {
            .register => |reg| blk: {
                for (call_saved, 0..) |saved, saved_index| {
                    if (reg == saved) break :blk @as(usize, base) + saved_index;
                }
                unreachable;
            },
            .stack => |saved_slot| @as(usize, saved_slot),
            .dead => unreachable,
        };
    }

    fn loadCallArguments(self: *Emitter, op: *ir.Operation, base: u16) BackendError!void {
        var integer_index: usize = 0;
        var floating_index: usize = 0;
        for (op.operands.items) |operand| {
            const slot = try self.savedSlot(op, operand.value, base);
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
                if (!isHostAddress(operand.value.type))
                    try self.normalize(target, try scalarIntegerKind(self.diagnose, op, operand.value.type));
                integer_index += 1;
            }
        }
    }

    /// x0 = the byte size. A count whose bytes pass 2^64 traps, so malloc never sees a
    /// wrapped size: CMP XZR, X0, LSR #(64 - shift) is equal only when the shifted-out bits
    /// are zero.
    fn loadAllocationSize(self: *Emitter, op: *ir.Operation, base: u16, allocation: Allocation) BackendError!void {
        switch (allocation) {
            .static_bytes => |bytes| try self.emitMoveImmediate(.x0, bytes),
            .dynamic_shift => |shift| {
                const count = (MemrefDialect.AllocOp{ .op = op }).getDynamicSize().?;
                const slot = try self.savedSlot(op, count, base);
                try self.emitInstruction(encoding.LoadStoreRegImm.ldr(GPR.x0.encode(), registers.SP.encoded, @intCast(slot), .x));
                if (shift == 0) return;
                try self.emitInstruction(encoding.AddSubShiftedRegister.cmpShiftedReg(registers.ZR.encoded, GPR.x0.encode(), .lsr, @intCast(64 - @as(u7, shift)), .x));
                try self.requireCondition(.eq);
                try self.emitInstruction(encoding.AddSubShiftedRegister.addShiftedReg(GPR.x0.encode(), registers.ZR.encoded, GPR.x0.encode(), .lsl, shift, .x));
            },
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

    /// Calls the C function behind a library operation, under the name x64 calls and the
    /// runtime registers: `exp` for f64 and `expf` for f32. The operands share the result's
    /// width. An unread result makes no call, as for every other floating operation.
    fn emitLibraryCall(self: *Emitter, op: *ir.Operation, operation: ScalarOp) BackendError!void {
        const function = libraryFunction(operation).?;
        const value = op.getResult(0).?;
        const single = isF32(value.type);
        if (!single and !isF64(value.type))
            return self.reject(op, "aarch64 library function requires an f32 or f64 result", BackendError.UnsupportedOperation);
        for (op.operands.items) |operand| {
            if (!isFloating(operand.value.type) or isF32(operand.value.type) != single)
                return self.reject(op, "aarch64 library function requires operands of its result's width", BackendError.UnsupportedOperation);
        }
        if (single and function.single == null)
            return self.reject(op, "aarch64 log1p and expm1 require f64", BackendError.UnsupportedOperation);
        if (value.hasNoUses()) return;
        try self.emitRuntimeCall(op, if (single) function.single.? else function.double, .operands);
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
        if (operation == .bitcast) {
            const source = try scalarIntegerKind(self.diagnose, op, op.operands.items[0].value.type);
            if (!bitcastPair(source, kind))
                return self.reject(op, bitcast_refusal, BackendError.UnsupportedOperation);
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

    /// Refuses `op` past one of the target's bounds, keeping the figures for the failure report
    /// and stating them in the diagnostic.
    fn rejectExcess(self: *Emitter, op: *ir.Operation, excess: Excess) BackendError {
        self.excess = excess;
        var buffer: [excess_message_capacity]u8 = undefined;
        return self.reject(op, excessMessage(&buffer, excess), BackendError.UnsupportedOperation);
    }
};

pub const excess_message_capacity = 256;

/// "aarch64 refused <the excess>", the sentence a refusal past a bound carries.
pub fn excessMessage(buffer: *[excess_message_capacity]u8, excess: Excess) []const u8 {
    return std.fmt.bufPrint(buffer, "aarch64 refused {f}", .{excess}) catch
        "aarch64 refused a construct past one of its bounds";
}

/// Publishes the refused operation's exact name and location in its diagnostic.
fn refuse(op: *ir.Operation, message: []const u8, err: BackendError) BackendError {
    var diagnostic = op.emitError(message);
    defer diagnostic.deinit();
    _ = diagnostic.emit() catch {};
    return err;
}

/// Refuses `op` while admitting a module, and records where for the runtime's report.
fn refuseAt(located: *Refused, op: *ir.Operation, message: []const u8, err: BackendError) BackendError {
    located.* = .{ .operation = op };
    return refuse(op, message, err);
}

/// Refuses `op` while admitting a module past one of the target's bounds, with the figures in
/// both the record and the message.
fn refuseExcessAt(located: *Refused, op: *ir.Operation, excess: Excess) BackendError {
    located.* = .{ .operation = op, .excess = excess };
    var buffer: [excess_message_capacity]u8 = undefined;
    return refuse(op, excessMessage(&buffer, excess), error.UnsupportedOperation);
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

const bitcast_refusal = "aarch64 bitcast requires two types of one width, neither bool nor index";

/// Whether a bitcast may join two scalar kinds: one width, and neither bool nor index.
fn bitcastPair(from: dialects.arith.ScalarKind, to: dialects.arith.ScalarKind) bool {
    for ([_]dialects.arith.ScalarKind{ from, to }) |kind| {
        if (kind == .bool or kind == .index) return false;
    }
    return dialects.arith.scalarBitWidth(from) == dialects.arith.scalarBitWidth(to);
}

/// The condition FCMP leaves for an ordered predicate. Every one but ne is false when
/// either operand is a NaN, and ne is true.
fn floatCondition(predicate: dialects.arith.CmpPredicate) ?encoding.Condition {
    return switch (predicate) {
        .eq => .eq,
        .ne => .ne,
        .lt => .mi,
        .le => .ls,
        .gt => .gt,
        .ge => .ge,
        else => null,
    };
}

fn isBool(typ: ir.Type) bool {
    return dialects.arith.scalarKindFromTypeName(typ.getDialectTypeName() orelse "") == .bool;
}

fn isI64(typ: ir.Type) bool {
    return dialects.arith.scalarKindFromTypeName(typ.getDialectTypeName() orelse "") == .i64;
}

fn overflowShape(op: *const ir.Operation) bool {
    if (op.operands.items.len != 2 or op.results.items.len != 2) return false;
    for (op.operands.items) |operand| if (!isI64(operand.value.type)) return false;
    return isI64(op.results.items[0].type) and isBool(op.results.items[1].type);
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

fn expectTrap(witness: *Witness, args: []const i64, declared: anyerror) !void {
    var evaluator = @import("../../root.zig").eval.Evaluator.init(witness.arena.allocator(), &witness.ctx);
    defer evaluator.deinit();
    try evaluator.setRootOperation(witness.module);
    var attributes: [max_arguments]ir.Attribute = undefined;
    for (args, 0..) |arg, index| attributes[index] = try witness.ctx.getI64Attr(arg);
    try std.testing.expectError(declared, evaluator.evaluateFunctionOp(witness.function.op, attributes[0..args.len]));
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

/// The evaluator observes raw Attribute signs for abs, while the typed contract
/// treats unsigned abs as identity and signed abs as wrapping arithmetic.
fn expectTypedAbsolute(witness: *Witness, args: []const i64, raw: i64, kind: dialects.arith.ScalarKind) !void {
    const input = canonicalInteger(raw, kind);
    const expected = if (Emitter.unsignedKind(kind)) input else dialects.arith.scalar.absWrap(input, dialects.arith.scalarBitWidth(kind));
    try std.testing.expectEqual(expected, (try witness.run(args)).?);
}

const OverflowCase = struct { value: i64, overflow: bool };

/// The exact result in 128 bits, read against i64's range: no flag and no SMULH involved.
fn exactOverflow(kind: Emitter.Overflow, lhs: i64, rhs: i64) OverflowCase {
    const exact: i128 = switch (kind) {
        .add => @as(i128, lhs) + rhs,
        .sub => @as(i128, lhs) - rhs,
        .mul => @as(i128, lhs) * rhs,
    };
    return .{
        .value = @truncate(exact),
        .overflow = exact < std.math.minInt(i64) or exact > std.math.maxInt(i64),
    };
}

/// Each signed i64 edge an overflow test turns on: the extremes, their neighbours, the
/// square-root boundary of a product and one word with alternating bits.
const overflow_operands = [_]i64{
    std.math.minInt(i64), std.math.minInt(i64) + 1, -3037000500,          -3037000499,
    -(1 << 32),           -2,                       -1,                   0,
    1,                    2,                        1 << 32,              3037000499,
    3037000500,           std.math.maxInt(i64) - 1, std.math.maxInt(i64), 0x5555555555555555,
};

const OverflowUse = enum { value, flag, both };

/// Both results meet in `select(flag, not(value), value)`, which keeps the value and still
/// shows the flag.
fn joinOverflow(witness: *Witness, value: *ir.Value, flag: *ir.Value) !*ir.Value {
    const block = witness.function.getEntryBlock();
    const inverted = try ArithDialect.NotOp.create(&witness.ctx, .unknown, value);
    try block.addOperation(inverted.op);
    const chosen = try ArithDialect.SelectOp.create(&witness.ctx, .unknown, flag, inverted.getResult(), value);
    try block.addOperation(chosen.op);
    return chosen.getResult();
}

/// One result shape per liveness case.
fn overflowReturn(
    witness: *Witness,
    comptime Op: type,
    lhs: *ir.Value,
    rhs: *ir.Value,
    use: OverflowUse,
) !void {
    const checked = try Op.create(&witness.ctx, .unknown, lhs, rhs);
    try witness.function.getEntryBlock().addOperation(checked.op);
    const returned = switch (use) {
        .value => checked.getResult(),
        .flag => checked.getOverflow(),
        .both => try joinOverflow(witness, checked.getResult(), checked.getOverflow()),
    };
    try witness.ret(&.{returned});
}

fn expectedOverflowReturn(case: OverflowCase, use: OverflowUse) i64 {
    return switch (use) {
        .value => case.value,
        .flag => @intFromBool(case.overflow),
        .both => if (case.overflow) ~case.value else case.value,
    };
}

const overflow_ops = .{
    .{ ArithDialect.AddoOp, Emitter.Overflow.add },
    .{ ArithDialect.SuboOp, Emitter.Overflow.sub },
    .{ ArithDialect.MuloOp, Emitter.Overflow.mul },
};

/// Returns `sqrt(a)` or `fma(a, b, c)` over the witness arguments.
fn rootOrFusedReturn(witness: *Witness, fused: bool) !void {
    const args = witness.function.getArguments();
    const entry = witness.function.getEntryBlock();
    const result = if (fused) blk: {
        const fma = try ArithDialect.FmaOp.create(&witness.ctx, .unknown, args[0], args[1], args[2]);
        try entry.addOperation(fma.op);
        break :blk fma.getResult();
    } else blk: {
        const sqrt = try ArithDialect.SqrtOp.create(&witness.ctx, .unknown, args[0]);
        try entry.addOperation(sqrt.op);
        break :blk sqrt.getResult();
    };
    const ret = try FuncDialect.ReturnOp.create(&witness.ctx, .unknown, &.{result});
    try entry.addOperation(ret.op);
}

/// Emits `witness` returning `op(args)` for a unary library operation or floor.
fn libraryReturn(witness: *Witness, comptime Op: type) !void {
    const entry = witness.function.getEntryBlock();
    const call = try Op.create(&witness.ctx, .unknown, witness.function.getArgument(0));
    try entry.addOperation(call.op);
    const ret = try FuncDialect.ReturnOp.create(&witness.ctx, .unknown, &.{call.getResult()});
    try entry.addOperation(ret.op);
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
