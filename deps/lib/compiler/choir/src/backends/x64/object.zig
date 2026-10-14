const std = @import("std");
const sys = @import("sys");
const alloc_arena = @import("alloc_arena");
const alloc_observe = @import("alloc_observe");
const ir = @import("../../core/root.zig");
const diagnostics = @import("../../root.zig").diagnostics;
const artifact = @import("../root.zig").artifact;
const elf_object = @import("../root.zig").elf_object;
const interface = @import("../root.zig").interface;
const machine = @import("../root.zig").machine_code;
const boundary = @import("../root.zig").signature;
const datasym = @import("data.zig");
const emit = @import("emit.zig");
const failures = @import("failures.zig");
const sysv = @import("abi.zig");

const BackendError = interface.BackendError;
const Allocator = std.mem.Allocator;

pub const ModuleCompileOptions = ir.ThreadingOptions;

pub fn target() artifact.Target {
    return .{
        .architecture = .x86_64,
        .triple = "x86_64-unknown-linux-gnu",
        .cpu = "x86-64",
    };
}

pub fn abi() artifact.Abi {
    return .{
        .name = "sysv",
        .calling_convention = "c",
        .object_format = "elf",
        .pointer_width_bits = 64,
        .endianness = .little,
    };
}

fn artifactRelocations(
    allocator: Allocator,
    call_relocations: []const machine.CallRelocation,
    data_relocations: []const machine.DataRelocation,
) BackendError![]artifact.Relocation {
    const count = std.math.add(usize, call_relocations.len, data_relocations.len) catch {
        return BackendError.OutOfMemory;
    };
    const relocations = allocator.alloc(artifact.Relocation, count) catch {
        return BackendError.OutOfMemory;
    };
    for (call_relocations, 0..) |relocation, index| {
        relocations[index] = .{
            .offset = relocation.offset,
            .symbol = relocation.target,
            .kind = .call,
            // An absolute call is the width a call relocation has unless it says otherwise.
            .width_bits = if (relocation.width_bits == 64) null else relocation.width_bits,
        };
    }
    for (data_relocations, call_relocations.len..) |relocation, index| {
        relocations[index] = .{
            .offset = relocation.offset,
            .symbol = relocation.target,
            .kind = .absolute,
            .addend = relocation.addend,
            .width_bits = relocation.width_bits,
        };
    }
    return relocations;
}

/// Emits `func` as machine code with its call relocations, data symbols, and data relocations,
/// which the caller frees with `deinit(allocator)`.
/// Fails with `error.CodeGenFailed` when emission fails, and reports one error diagnostic located
/// at the innermost operation whose emission failed, or otherwise at `func`.
/// Fails with `error.OutOfMemory` when an allocation fails, and reports nothing.
pub fn emitFunctionMachineCode(allocator: Allocator, func: *ir.Operation) BackendError!machine.MachineCode {
    var failure: ?failures.Failure = null;
    errdefer if (failure) |located| located.report();
    return try emitFunctionMachineCodeWithFailure(allocator, func, null, &failure);
}

/// Emits `func` as machine code exactly as `emitFunctionMachineCode` does, and reports nothing.
/// Sets `failure` to the stage, the operation, and the emitter's own error when emission fails,
/// which is the specific name `BackendError` has no member for and which `error.CodeGenFailed`
/// stands in for. A caller states it in its own refusal, or reports it with `failure.report()`.
/// `failure` must be null on entry, and the operation it names lives as long as `func` does.
/// A call to a function `image` names takes a 32-bit displacement, so the caller lays every one
/// of them in the same text as `func`. Without `image` every call takes an absolute address.
pub fn emitFunctionMachineCodeWithFailure(
    allocator: Allocator,
    func: *ir.Operation,
    image: ?*const machine.ImageFunctions,
    failure: *?failures.Failure,
) BackendError!machine.MachineCode {
    std.debug.assert(failure.* == null);
    var emitter = emit.Emitter.init(allocator);
    defer emitter.deinit();
    emitter.image_functions = image;
    emitter.emitFunction(func) catch |err| {
        const operation = emitter.failed_operation orelse func;
        std.debug.assert(failures.Failure.namesBound(err) == (emitter.excess != null));
        failure.* = .{ .stage = .emit, .operation = operation, .err = err, .excess = emitter.excess };
        return switch (err) {
            error.OutOfMemory => BackendError.OutOfMemory,
            else => BackendError.CodeGenFailed,
        };
    };

    const code = emitter.getCode();
    std.debug.assert(code.len != 0);

    const owned_code = allocator.dupe(u8, code) catch return BackendError.OutOfMemory;
    errdefer allocator.free(owned_code);

    const relocations = allocator.alloc(machine.CallRelocation, emitter.call_relocations.items.len) catch {
        return BackendError.OutOfMemory;
    };
    errdefer allocator.free(relocations);

    const data_symbols = allocator.dupe(machine.DataSymbol, emitter.data_symbols.items()) catch {
        return BackendError.OutOfMemory;
    };
    errdefer allocator.free(data_symbols);

    const data_relocations = allocator.alloc(machine.DataRelocation, emitter.data_relocations.items.len) catch {
        return BackendError.OutOfMemory;
    };
    errdefer allocator.free(data_relocations);

    for (emitter.call_relocations.items, 0..) |reloc, index| {
        relocations[index] = reloc;
    }
    for (emitter.data_relocations.items, 0..) |reloc, index| {
        data_relocations[index] = reloc;
    }

    return .{
        .code = owned_code,
        .relocations = relocations,
        .data_symbols = data_symbols,
        .data_relocations = data_relocations,
    };
}

/// Compiles one function into a machine-code artifact for the JIT loader.
/// The artifact records the function's signature. Each data symbol the function references
/// travels as a raw buffer beside the code.
/// Fails with `error.UnsupportedOperation` when this backend cannot record, pass, or return the
/// function's parameter and result types.
pub fn compileFunctionToArtifact(
    allocator: Allocator,
    func: *ir.Operation,
    function_name: []const u8,
) BackendError!artifact.Artifact {
    const signature = boundary.ofFunction(func) catch return BackendError.UnsupportedOperation;
    if (!sysv.admitsSignature(&signature)) return BackendError.UnsupportedOperation;
    var machine_code = try emitFunctionMachineCode(allocator, func);
    defer machine_code.deinit(allocator);

    const data = allocator.alloc(artifact.DataBuffer, machine_code.data_symbols.len) catch {
        return BackendError.OutOfMemory;
    };
    defer allocator.free(data);
    for (machine_code.data_symbols, data) |symbol, *buffer| {
        buffer.* = .{
            .name = symbol.name,
            .bytes = symbol.bytes,
            .alignment = symbol.alignment,
            .binding = switch (symbol.binding) {
                .local => .local,
                .global => .external,
            },
        };
    }
    const relocations = try artifactRelocations(
        allocator,
        machine_code.relocations,
        machine_code.data_relocations,
    );
    defer allocator.free(relocations);

    return artifact.machineCodeArtifact(
        allocator,
        target(),
        abi(),
        function_name,
        signature,
        machine_code.code,
        data,
        relocations,
    ) catch BackendError.OutOfMemory;
}

pub fn compileFunctionToObjectFile(
    allocator: Allocator,
    func: *ir.Operation,
    function_name: []const u8,
) BackendError!artifact.Artifact {
    var machine_code = try emitFunctionMachineCode(allocator, func);
    defer machine_code.deinit(allocator);

    const object = elf_object.buildX86_64MachineCodeObject(allocator, .{
        .entry_symbol = function_name,
        .code = machine_code.code,
        .relocations = machine_code.relocations,
        .data_relocations = machine_code.data_relocations,
        .data_symbols = machine_code.data_symbols,
    }) catch |err| switch (err) {
        error.OutOfMemory => return BackendError.OutOfMemory,
        else => return BackendError.CodeGenFailed,
    };
    defer allocator.free(object);

    const relocations = try artifactRelocations(allocator, machine_code.relocations, machine_code.data_relocations);
    defer allocator.free(relocations);

    return artifact.objectFileArtifact(
        allocator,
        target(),
        abi(),
        function_name,
        object,
        relocations,
    ) catch BackendError.OutOfMemory;
}

pub fn compileModuleToObjectFile(
    allocator: Allocator,
    lowered_module: *ir.Operation,
    entry_name: []const u8,
    options: ModuleCompileOptions,
) BackendError!artifact.Artifact {
    var functions = std.ArrayListUnmanaged(*ir.Operation).empty;
    defer functions.deinit(allocator);
    try appendFunctionDefinitions(allocator, lowered_module, &functions);
    if (!hasFunctionDefinition(functions.items, entry_name)) return BackendError.FunctionNotFound;

    var defined_functions = std.StringHashMapUnmanaged(void){};
    defer defined_functions.deinit(allocator);
    for (functions.items) |func| {
        const name = functionSymbolName(func) orelse return BackendError.CodeGenFailed;
        if (defined_functions.contains(name)) return BackendError.CodeGenFailed;
        defined_functions.put(allocator, name, {}) catch return BackendError.OutOfMemory;
    }

    var text = std.ArrayListUnmanaged(u8).empty;
    defer text.deinit(allocator);
    var text_symbols = std.ArrayListUnmanaged(elf_object.TextSymbol).empty;
    defer text_symbols.deinit(allocator);
    var call_relocations = std.ArrayListUnmanaged(machine.CallRelocation).empty;
    defer call_relocations.deinit(allocator);
    var data_symbols: machine.DataSymbolSet = .{};
    defer data_symbols.deinit(allocator);
    var data_relocations = std.ArrayListUnmanaged(machine.DataRelocation).empty;
    defer data_relocations.deinit(allocator);

    datasym.appendModuleGlobals(allocator, &data_symbols, lowered_module) catch |err| switch (err) {
        error.OutOfMemory => return BackendError.OutOfMemory,
        else => {
            failures.Failure.report(.{ .stage = .emit, .operation = lowered_module, .err = err });
            return BackendError.CodeGenFailed;
        },
    };

    const emitted_functions = try emitModuleFunctions(allocator, functions.items, &defined_functions, options);
    defer deinitEmittedFunctions(allocator, emitted_functions);

    for (emitted_functions, functions.items) |emitted, func| {
        const aligned_offset = alignForward(text.items.len, 16);
        text.appendNTimes(allocator, 0, aligned_offset - text.items.len) catch {
            return BackendError.OutOfMemory;
        };

        text.appendSlice(allocator, emitted.machine_code.code) catch return BackendError.OutOfMemory;
        text_symbols.append(allocator, .{
            .name = emitted.name,
            .offset = @intCast(aligned_offset),
            .size = @intCast(emitted.machine_code.code.len),
        }) catch return BackendError.OutOfMemory;

        for (emitted.machine_code.relocations) |relocation| {
            call_relocations.append(allocator, .{
                .offset = aligned_offset + relocation.offset,
                .target = relocation.target,
                .width_bits = relocation.width_bits,
            }) catch return BackendError.OutOfMemory;
        }
        for (emitted.machine_code.data_symbols) |symbol| {
            try putDataSymbol(allocator, &data_symbols, symbol, func);
        }
        for (emitted.machine_code.data_relocations) |relocation| {
            data_relocations.append(allocator, .{
                .offset = aligned_offset + relocation.offset,
                .target = relocation.target,
                .addend = relocation.addend,
                .width_bits = relocation.width_bits,
            }) catch return BackendError.OutOfMemory;
        }
    }

    const object = elf_object.buildX86_64MachineCodeObject(allocator, .{
        .entry_symbol = entry_name,
        .code = text.items,
        .text_symbols = text_symbols.items,
        .relocations = call_relocations.items,
        .data_relocations = data_relocations.items,
        .data_symbols = data_symbols.items(),
    }) catch |err| switch (err) {
        error.OutOfMemory => return BackendError.OutOfMemory,
        else => return BackendError.CodeGenFailed,
    };
    defer allocator.free(object);

    const relocations = try artifactRelocations(allocator, call_relocations.items, data_relocations.items);
    defer allocator.free(relocations);

    var out = artifact.Artifact.init(allocator, .{
        .kind = .object_file,
        .target = target(),
        .abi = abi(),
    }) catch return BackendError.OutOfMemory;
    errdefer out.deinit();

    out.payload.addBuffer(.{
        .name = entry_name,
        .format = .object_file,
        .bytes = object,
        .alignment = 8,
    }) catch return BackendError.OutOfMemory;
    for (relocations) |relocation| {
        out.linkage.addRelocation(relocation) catch return BackendError.OutOfMemory;
    }
    for (functions.items) |func| {
        out.linkage.addProvided(.{
            .name = functionSymbolName(func) orelse return BackendError.CodeGenFailed,
            .kind = .function,
            .binding = .external,
        }) catch return BackendError.OutOfMemory;
    }
    for (call_relocations.items) |relocation| {
        if (defined_functions.contains(relocation.target)) continue;
        if (!out.linkage.hasRequired(relocation.target)) {
            out.linkage.addRequired(.{
                .name = relocation.target,
                .kind = .function,
                .binding = .external,
            }) catch return BackendError.OutOfMemory;
        }
    }

    return out;
}

fn appendFunctionDefinitions(
    allocator: Allocator,
    module: *ir.Operation,
    definitions: *std.ArrayListUnmanaged(*ir.Operation),
) BackendError!void {
    const region = module.getRegion(0) orelse return BackendError.FunctionNotFound;
    const block = region.getEntryBlock() orelse return BackendError.FunctionNotFound;

    var op_iter = block.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        op_iter = op.next_op;
        if (!ir.inspection.isFunctionDefinition(op)) continue;
        definitions.append(allocator, op) catch return BackendError.OutOfMemory;
    }
}

fn hasFunctionDefinition(functions: []const *ir.Operation, name: []const u8) bool {
    for (functions) |function| {
        const actual = functionSymbolName(function) orelse continue;
        if (std.mem.eql(u8, actual, name)) return true;
    }
    return false;
}

const EmittedFunction = struct {
    name: []const u8,
    machine_code: machine.MachineCode,

    fn deinit(self: *EmittedFunction, allocator: Allocator) void {
        self.machine_code.deinit(allocator);
        self.* = undefined;
    }
};

fn emitModuleFunctions(
    allocator: Allocator,
    functions: []const *ir.Operation,
    image: *const machine.ImageFunctions,
    options: ModuleCompileOptions,
) BackendError![]EmittedFunction {
    if (options.workerCount(functions.len) > 1) {
        return try emitModuleFunctionsParallel(allocator, functions, image, options);
    }
    return try emitModuleFunctionsSerial(allocator, functions, image);
}

fn emitModuleFunctionsSerial(
    allocator: Allocator,
    functions: []const *ir.Operation,
    image: *const machine.ImageFunctions,
) BackendError![]EmittedFunction {
    if (functions.len == 0) return &.{};

    const emitted = allocator.alloc(EmittedFunction, functions.len) catch return BackendError.OutOfMemory;
    var written: usize = 0;
    errdefer {
        deinitEmittedFunctionItems(allocator, emitted[0..written]);
        allocator.free(emitted);
    }

    for (functions, 0..) |func, index| {
        var failure: ?failures.Failure = null;
        errdefer if (failure) |located| located.report();
        emitted[index] = try emitOneModuleFunction(allocator, func, image, &failure);
        written += 1;
    }

    return emitted;
}

fn emitModuleFunctionsParallel(
    allocator: Allocator,
    functions: []const *ir.Operation,
    image: *const machine.ImageFunctions,
    options: ModuleCompileOptions,
) BackendError![]EmittedFunction {
    if (functions.len == 0) return &.{};

    const worker_allocator = options.workerAllocator(allocator);
    const slots = allocator.alloc(EmitWorkerSlot, functions.len) catch return BackendError.OutOfMemory;
    defer allocator.free(slots);
    for (slots) |*slot| slot.* = .{};
    defer deinitEmitWorkerSlots(worker_allocator, slots);

    var batch = EmitWorkerBatch{
        .allocator = worker_allocator,
        .functions = functions,
        .image = image,
        .slots = slots,
    };

    const parallel = ir.threading.parallelForEachIndex(options, functions.len, &batch, runEmitWorker);
    parallel catch |err| switch (err) {
        error.OutOfMemory => return BackendError.OutOfMemory,
        else => return BackendError.CodeGenFailed,
    };

    if (firstFailedEmitWorker(slots)) |slot| {
        if (slot.failure) |located| located.report();
        return slot.result.err;
    }

    const emitted = allocator.alloc(EmittedFunction, functions.len) catch return BackendError.OutOfMemory;
    var written: usize = 0;
    errdefer {
        deinitEmittedFunctionItems(allocator, emitted[0..written]);
        allocator.free(emitted);
    }

    const transfer_results = sameAllocator(allocator, worker_allocator);
    for (slots, 0..) |*slot, index| {
        const worker_emitted = switch (slot.result) {
            .ok => |result| result,
            .pending => unreachable,
            .err => unreachable,
        };
        emitted[index] = if (transfer_results)
            worker_emitted
        else
            try cloneEmittedFunction(allocator, worker_emitted);
        written += 1;
        if (transfer_results) slot.result = .pending;
    }

    return emitted;
}

fn cloneEmittedFunction(allocator: Allocator, emitted: EmittedFunction) BackendError!EmittedFunction {
    return .{
        .name = emitted.name,
        .machine_code = try cloneMachineCode(allocator, emitted.machine_code),
    };
}

fn cloneMachineCode(allocator: Allocator, code: machine.MachineCode) BackendError!machine.MachineCode {
    var cloned = machine.MachineCode{
        .code = allocator.dupe(u8, code.code) catch return BackendError.OutOfMemory,
        .relocations = &.{},
        .data_symbols = &.{},
        .data_relocations = &.{},
    };
    errdefer cloned.deinit(allocator);

    cloned.relocations = allocator.dupe(machine.CallRelocation, code.relocations) catch return BackendError.OutOfMemory;
    cloned.data_symbols = allocator.dupe(machine.DataSymbol, code.data_symbols) catch return BackendError.OutOfMemory;
    cloned.data_relocations = allocator.dupe(machine.DataRelocation, code.data_relocations) catch return BackendError.OutOfMemory;

    return cloned;
}

fn emitOneModuleFunction(
    allocator: Allocator,
    func: *ir.Operation,
    image: *const machine.ImageFunctions,
    failure: *?failures.Failure,
) BackendError!EmittedFunction {
    return .{
        .name = functionSymbolName(func) orelse return BackendError.CodeGenFailed,
        .machine_code = try emitFunctionMachineCodeWithFailure(allocator, func, image, failure),
    };
}

const EmitWorkerResult = union(enum) {
    pending,
    ok: EmittedFunction,
    err: BackendError,
};

const EmitWorkerSlot = struct {
    result: EmitWorkerResult = .pending,
    failure: ?failures.Failure = null,
};

const EmitWorkerBatch = struct {
    allocator: Allocator,
    functions: []const *ir.Operation,
    /// Read by every worker at once and written by none.
    image: *const machine.ImageFunctions,
    slots: []EmitWorkerSlot,
};

fn runEmitWorker(batch: *EmitWorkerBatch, index: usize) void {
    const slot = &batch.slots[index];
    const func = batch.functions[index];
    slot.result = if (emitOneModuleFunction(batch.allocator, func, batch.image, &slot.failure)) |emitted|
        .{ .ok = emitted }
    else |err|
        .{ .err = err };
}

fn firstFailedEmitWorker(slots: []const EmitWorkerSlot) ?*const EmitWorkerSlot {
    for (slots) |*slot| {
        if (slot.result == .err) return slot;
    }
    return null;
}

fn deinitEmittedFunctions(allocator: Allocator, emitted: []EmittedFunction) void {
    deinitEmittedFunctionItems(allocator, emitted);
    if (emitted.len != 0) allocator.free(emitted);
}

fn deinitEmittedFunctionItems(allocator: Allocator, emitted: []EmittedFunction) void {
    for (emitted) |*function| function.deinit(allocator);
}

fn deinitEmitWorkerSlots(allocator: Allocator, slots: []EmitWorkerSlot) void {
    for (slots) |*slot| {
        switch (slot.result) {
            .ok => |*function| function.deinit(allocator),
            else => {},
        }
    }
}

fn sameAllocator(left: Allocator, right: Allocator) bool {
    return left.ptr == right.ptr and left.vtable == right.vtable;
}

fn functionSymbolName(op: *ir.Operation) ?[]const u8 {
    if (!std.mem.eql(u8, op.name.name, "func.func")) return null;
    return ir.SymbolTable.getSymbolName(op);
}

fn putDataSymbol(
    allocator: Allocator,
    symbols: *machine.DataSymbolSet,
    symbol: machine.DataSymbol,
    func: *ir.Operation,
) BackendError!void {
    symbols.put(allocator, symbol) catch |err| switch (err) {
        error.OutOfMemory => return BackendError.OutOfMemory,
        error.InvalidDataSymbol,
        error.ConflictingDataSymbol,
        => {
            failures.Failure.report(.{ .stage = .emit, .operation = func, .err = err });
            return BackendError.CodeGenFailed;
        },
    };
}

fn alignForward(value: usize, alignment: usize) usize {
    const mask = alignment - 1;
    return (value + mask) & ~mask;
}

/// Builds `function_count` functions named `entry`, `f01`, `f02` and so on. Each calls the next,
/// so the object carries a relocation per function and its symbol order is visible in the bytes.
/// Bodies differ in length, so parallel lanes finish unevenly.
fn buildCallChainModule(ctx: *ir.Context, comptime function_count: usize) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getFile("object-determinism.choir", 1, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    var names: [function_count][8]u8 = undefined;
    var name_slices: [function_count][]const u8 = undefined;
    for (&names, &name_slices, 0..) |*storage, *name, index| {
        name.* = if (index == 0) "entry" else try std.fmt.bufPrint(storage, "f{d:0>2}", .{index});
    }
    for (name_slices, 0..) |name, index| {
        const function = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{i64_type});
        try module.getBodyBlock().addOperation(function.op);
        const body = function.getEntryBlock();
        const seed_value: i64 = @intCast(index * 7 + 1);
        const seed = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, seed_value);
        try body.addOperation(seed.op);
        var value = seed.getResult();
        for (0..index % 5) |_| {
            const sum = try ArithDialect.AddOp.create(ctx, loc, value, value);
            try body.addOperation(sum.op);
            value = sum.getResult();
        }
        if (index + 1 < function_count) {
            const callee = name_slices[index + 1];
            const call = try FuncDialect.CallOp.create(ctx, loc, callee, &.{}, &.{i64_type});
            try body.addOperation(call.op);
            const sum = try ArithDialect.AddOp.create(ctx, loc, value, call.getResult(0).?);
            try body.addOperation(sum.op);
            value = sum.getResult();
        }
        const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{value});
        try body.addOperation(ret.op);
    }

    return module.op;
}

/// Reads a relocatable object back through `std.elf`.
///
/// The package's own reader is a set of private helpers inside the writer's own file, so a pin
/// that used them could agree with a writer that had the layout wrong. `std.elf` shares no code
/// with `backends/elf.zig` and its typed section and symbol records are the independent account.
const ObjectView = struct {
    bytes: []const u8,

    const Ehdr = std.elf.Elf64.Ehdr;
    const Shdr = std.elf.Elf64.Shdr;
    const Sym = std.elf.Elf64.Sym;
    const Rela = std.elf.Elf64.Rela;

    fn value(self: ObjectView, comptime T: type, offset: usize) T {
        return std.mem.bytesToValue(T, self.bytes[offset..][0..@sizeOf(T)]);
    }

    fn record(self: ObjectView, comptime T: type, section: Shdr, index: usize) T {
        return self.value(T, @as(usize, @intCast(section.offset)) + index * @sizeOf(T));
    }

    fn count(comptime T: type, section: Shdr) usize {
        return @as(usize, @intCast(section.size)) / @sizeOf(T);
    }

    fn sectionAt(self: ObjectView, index: usize) Shdr {
        const head = self.value(Ehdr, 0);
        return self.value(Shdr, @as(usize, @intCast(head.shoff)) + index * @sizeOf(Shdr));
    }

    fn stringAt(self: ObjectView, table: Shdr, offset: u32) []const u8 {
        const start = @as(usize, @intCast(table.offset)) + offset;
        const end = std.mem.indexOfScalarPos(u8, self.bytes, start, 0) orelse self.bytes.len;
        return self.bytes[start..end];
    }

    fn sectionIndex(self: ObjectView, name: []const u8) ?u16 {
        const head = self.value(Ehdr, 0);
        const names = self.sectionAt(head.shstrndx);
        for (0..head.shnum) |index| {
            const section = self.sectionAt(index);
            if (!std.mem.eql(u8, self.stringAt(names, section.name), name)) continue;
            return @intCast(index);
        }
        return null;
    }

    fn symbol(self: ObjectView, name: []const u8) ?Sym {
        const symtab = self.sectionAt(self.sectionIndex(".symtab") orelse return null);
        const strtab = self.sectionAt(symtab.link);
        for (0..count(Sym, symtab)) |index| {
            const entry = self.record(Sym, symtab, index);
            if (!std.mem.eql(u8, self.stringAt(strtab, entry.name), name)) continue;
            return entry;
        }
        return null;
    }

    /// How many `.rela.text` entries name `symbol_name`, which is one per reference from code.
    fn textRelocations(self: ObjectView, symbol_name: []const u8) usize {
        const rela = self.sectionAt(self.sectionIndex(".rela.text") orelse return 0);
        const symtab = self.sectionAt(self.sectionIndex(".symtab") orelse return 0);
        const strtab = self.sectionAt(symtab.link);
        var matches: usize = 0;
        for (0..count(Rela, rela)) |index| {
            const entry = self.record(Rela, rela, index);
            const named = self.record(Sym, symtab, entry.info.sym);
            if (!std.mem.eql(u8, self.stringAt(strtab, named.name), symbol_name)) continue;
            matches += 1;
        }
        return matches;
    }
};

/// Builds a module that declares a bump region and one function that names two of its globals.
///
/// `arena.limit` is declared and named by nothing, which is how the pin tells a symbol the object
/// carries because the module declares it from one a use site happened to register.
fn buildRegionProbeModule(ir_ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ir_ctx, .i64);
    const u8_type = try ArithDialect.getScalarType(ir_ctx, .u8);
    const index_type = try ArithDialect.getIndexType(ir_ctx);
    const arena_type = try MemrefDialect.getMemrefType1D(ir_ctx, 4096, u8_type, .host);
    const word_type = try MemrefDialect.getMemrefType1D(ir_ctx, 1, i64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(ir_ctx, loc);
    const module_block = module.getBodyBlock();
    const declarations = .{
        .{ "arena", arena_type, 16 },
        .{ "arena.cursor", word_type, 8 },
        .{ "arena.limit", word_type, 8 },
    };
    inline for (declarations) |declaration| {
        const global = try MemrefDialect.GlobalOp.create(ir_ctx, loc, .{
            .sym_name = declaration[0],
            .memref_type = declaration[1],
            .alignment = declaration[2],
        });
        try module_block.addOperation(global.op);
    }

    var probe = try FuncDialect.FuncOp.create(ir_ctx, loc, "probe", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(probe.op);
    const entry = probe.getEntryBlock();
    var zero = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, index_type, 0);
    try entry.addOperation(zero.op);
    const cursor = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena.cursor", word_type);
    try entry.addOperation(cursor.op);
    var used = try MemrefDialect.LoadOp.create(
        ir_ctx,
        loc,
        cursor.getResult(),
        zero.getResult(),
        i64_type,
    );
    try entry.addOperation(used.op);
    const first_base = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena", arena_type);
    try entry.addOperation(first_base.op);
    var first = try MemrefDialect.LoadOp.create(
        ir_ctx,
        loc,
        first_base.getResult(),
        used.getResult(),
        i64_type,
    );
    try entry.addOperation(first.op);
    const second_base = try MemrefDialect.GetGlobalOp.create(ir_ctx, loc, "arena", arena_type);
    try entry.addOperation(second_base.op);
    var second = try MemrefDialect.LoadOp.create(
        ir_ctx,
        loc,
        second_base.getResult(),
        probe.getArgument(0),
        i64_type,
    );
    try entry.addOperation(second.op);
    const sum = try ArithDialect.AddOp.create(ir_ctx, loc, first.getResult(), second.getResult());
    try entry.addOperation(sum.op);
    const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{sum.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

/// A function the emitter refuses, and the operation inside it that it refuses.
const OutsizedWhile = struct {
    function: *ir.Operation,
    loop: *ir.Operation,
};

/// Builds a function whose body is one `scf.while` carrying one value more than
/// `emit.max_while_carried_values`. It is the one emitter failure whose name states a bound that
/// was met rather than a module that disagrees with itself, so it is what a consumer most needs
/// to read off a failure.
fn buildOutsizedWhile(ctx: *ir.Context, allocator: Allocator) !OutsizedWhile {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getFile("object-reason.choir", 3, 1);
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "carry", &.{i64_type}, &.{i64_type});
    const entry = function.getEntryBlock();

    var inits: std.ArrayListUnmanaged(*ir.Value) = .empty;
    defer inits.deinit(allocator);
    var result_types: std.ArrayListUnmanaged(ir.Type) = .empty;
    defer result_types.deinit(allocator);
    for (0..emit.max_while_carried_values + 1) |_| {
        try inits.append(allocator, function.getArgument(0));
        try result_types.append(allocator, i64_type);
    }

    var loop = try dialects.ScfDialect.WhileOp.create(ctx, loc, inits.items, result_types.items);
    try entry.addOperation(loop.op);
    const before = loop.getBeforeBlock();
    const after = loop.getAfterBlock();
    const condition = try dialects.ScfDialect.ConditionOp.create(
        ctx,
        loc,
        before.arguments.items[0],
        before.arguments.items,
    );
    try before.addOperation(condition.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, after.arguments.items);
    try after.addOperation(yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(0).?});
    try entry.addOperation(ret.op);

    return .{ .function = function.op, .loop = loop.op };
}
