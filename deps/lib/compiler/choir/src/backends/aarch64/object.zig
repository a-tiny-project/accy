const std = @import("std");
const aarch64 = @import("root.zig");
const backends = @import("../root.zig");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const artifact = backends.artifact;
const macho = backends.macho;
const machine = backends.machine_code;
const Allocator = std.mem.Allocator;

/// Matches the current emitter's finite direct-call graph, including modules without calls.
pub const maximum_defined_functions = 64;
pub const CompileError = macho.ObjectError || backends.interface.BackendError ||
    machine.DataSymbolError || error{InvalidFunctionOrder};

pub fn target() artifact.Target {
    return .{
        .architecture = .aarch64,
        .triple = "aarch64-apple-macos",
        .vendor = "apple",
        .os = "macos",
        .cpu = "generic",
    };
}

pub fn abi() artifact.Abi {
    return .{
        .name = "apple-arm64",
        .calling_convention = "c",
        .object_format = "macho",
        .pointer_width_bits = 64,
        .endianness = .little,
    };
}

/// Emits every definition exactly once in explicit caller order. Whole-module admission
/// remains the existing backend's admission, including unused globals. No code is executed.
pub fn compileModuleToObjectFile(
    allocator: Allocator,
    module: *ir.Operation,
    entry_name: []const u8,
    function_order: []const []const u8,
) CompileError!artifact.Artifact {
    try aarch64.backend.lowerModule(module, null);
    const block = ir.inspection.moduleBodyBlock(module) orelse return error.InvalidFunctionOrder;
    var definitions: usize = 0;
    var operations = block.getOperations();
    while (operations.next()) |op| {
        if (ir.inspection.isFunctionDefinition(op)) definitions += 1;
    }
    if (definitions == 0 or definitions > maximum_defined_functions or
        definitions != function_order.len) return error.InvalidFunctionOrder;
    var ordered: [maximum_defined_functions]*ir.Operation = undefined;
    var found_entry = false;
    for (function_order, 0..) |name, index| {
        const function = ir.inspection.functionDefinitionByName(module, name) orelse
            return error.InvalidFunctionOrder;
        for (ordered[0..index]) |previous| {
            if (previous == function) return error.InvalidFunctionOrder;
        }
        ordered[index] = function;
        found_entry = found_entry or std.mem.eql(u8, name, entry_name);
    }
    if (!found_entry) return error.InvalidFunctionOrder;

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);
    var text_symbols: std.ArrayListUnmanaged(macho.TextSymbol) = .empty;
    defer text_symbols.deinit(allocator);
    var data: machine.DataSymbolSet = .{};
    defer data.deinit(allocator);
    var relocations: std.ArrayListUnmanaged(macho.Relocation) = .empty;
    defer relocations.deinit(allocator);
    operations = block.getOperations();
    while (operations.next()) |op| {
        if (!std.mem.eql(u8, op.name.name, dialects.MemrefDialect.GlobalOp.operation_name)) {
            continue;
        }
        const symbol = try backends.data.symbolOfGlobal(.{ .op = op });
        try data.put(allocator, symbol);
    }
    var emitter = try aarch64.backend.Emitter.init(allocator);
    defer emitter.deinit();
    for (ordered[0..definitions], function_order) |function, name| {
        emitter.discard();
        try emitter.emitFunction(function);
        try emitter.padCodeToImageAlignment();
        const offset = try macho.format.alignForward(text.items.len, 16);
        if (offset > std.math.maxInt(usize)) return error.ObjectSizeOverflow;
        try text.appendNTimes(allocator, 0, @as(usize, @intCast(offset)) - text.items.len);
        try text.appendSlice(allocator, emitter.code.items);
        try text_symbols.append(allocator, .{
            .name = name,
            .offset = offset,
            .size = emitter.code.items.len,
            .binding = .global,
        });
        for (emitter.data_symbols.items()) |symbol| try data.put(allocator, symbol);
        var library: usize = 0;
        for (emitter.calls.items, 0..) |relocation, index| {
            const from_library = library < emitter.library_calls.items.len and
                emitter.library_calls.items[library] == index;
            if (from_library) library += 1;
            try relocations.append(allocator, .{
                .offset = try macho.format.add(offset, relocation.offset),
                .symbol = if (from_library)
                    aarch64.backend.librarySymbolForObject(relocation.target)
                else
                    relocation.target,
                .kind = .call,
            });
        }
        std.debug.assert(library == emitter.library_calls.items.len);
        for (emitter.data_relocations.items) |relocation| try relocations.append(allocator, .{
            .offset = try macho.format.add(offset, relocation.offset),
            .symbol = relocation.target,
            .kind = .absolute,
            .addend = relocation.addend,
            .width_bits = relocation.width_bits,
        });
    }
    const bytes = try macho.buildRelocatableObject(allocator, .{
        .text = text.items,
        .text_symbols = text_symbols.items,
        .data_symbols = data.items(),
        .relocations = relocations.items,
    });
    defer allocator.free(bytes);
    var output = try artifact.Artifact.init(allocator, .{
        .kind = .object_file,
        .producer = "choir/aarch64/object",
        .target = target(),
        .abi = abi(),
    });
    errdefer output.deinit();
    try output.payload.addBuffer(.{ .name = entry_name, .format = .object_file, .bytes = bytes });
    for (text_symbols.items) |symbol| try output.linkage.addProvided(.{
        .name = symbol.name,
        .kind = .function,
        .binding = if (symbol.binding == .global) .external else .local,
    });
    for (data.items()) |symbol| try output.linkage.addProvided(.{
        .name = symbol.name,
        .kind = .data,
        .binding = if (symbol.binding == .global) .external else .local,
    });
    for (relocations.items) |relocation| {
        try output.linkage.addRelocation(.{
            .offset = relocation.offset,
            .symbol = relocation.symbol,
            .kind = relocation.kind,
            .addend = relocation.addend,
            .width_bits = relocation.width_bits,
        });
        if (output.linkage.hasProvided(relocation.symbol) or
            output.linkage.hasRequired(relocation.symbol)) continue;
        try output.linkage.addRequired(.{
            .name = relocation.symbol,
            .kind = if (relocation.kind == .call) .function else .data,
        });
    }
    return output;
}

fn fixture(ctx: *ir.Context, writable: bool) !*ir.Operation {
    const location = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getIndexType(ctx);
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const memref = try dialects.MemrefDialect.getMemrefType1D(ctx, 1, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, location);
    errdefer module.op.erase();
    const bytes = [_]u8{ 7, 0, 0, 0, 0, 0, 0, 0 };
    for ([_][]const u8{ "_unused", "_words" }) |name| {
        const global = try dialects.MemrefDialect.GlobalOp.create(ctx, location, .{
            .sym_name = name,
            .memref_type = memref,
            .alignment = 8,
            .constant = !writable,
            .initial = &bytes,
        });
        try module.getBodyBlock().addOperation(global.op);
    }
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(
        ctx,
        location,
        "_external",
        &.{word},
        &.{word},
    );
    try module.getBodyBlock().addOperation(external.op);
    const entry = try dialects.FuncDialect.FuncOp.create(
        ctx,
        location,
        "_entry",
        &.{word},
        &.{word},
    );
    try module.getBodyBlock().addOperation(entry.op);
    const internal = try dialects.FuncDialect.CallOp.create(
        ctx,
        location,
        "_helper",
        entry.getArguments(),
        &.{word},
    );
    try entry.getEntryBlock().addOperation(internal.op);
    const entry_return = try dialects.FuncDialect.ReturnOp.create(
        ctx,
        location,
        &.{internal.getResult(0).?},
    );
    try entry.getEntryBlock().addOperation(entry_return.op);
    const helper = try dialects.FuncDialect.FuncOp.create(
        ctx,
        location,
        "_helper",
        &.{word},
        &.{word},
    );
    try module.getBodyBlock().addOperation(helper.op);
    const address = try dialects.MemrefDialect.GetGlobalOp.create(ctx, location, "_words", memref);
    try helper.getEntryBlock().addOperation(address.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, location, index, 0);
    try helper.getEntryBlock().addOperation(zero.op);
    const load = try dialects.MemrefDialect.LoadOp.create(
        ctx,
        location,
        address.getResult(),
        zero.getResult(),
        word,
    );
    try helper.getEntryBlock().addOperation(load.op);
    const call = try dialects.FuncDialect.CallOp.create(
        ctx,
        location,
        "_external",
        &.{load.getResult()},
        &.{word},
    );
    try helper.getEntryBlock().addOperation(call.op);
    const helper_return = try dialects.FuncDialect.ReturnOp.create(ctx, location, &.{
        call.getResult(0).?,
    });
    try helper.getEntryBlock().addOperation(helper_return.op);
    const leaf = try dialects.FuncDialect.FuncOp.create(
        ctx,
        location,
        "_float",
        &.{floating},
        &.{floating},
    );
    try module.getBodyBlock().addOperation(leaf.op);
    const leaf_return = try dialects.FuncDialect.ReturnOp.create(
        ctx,
        location,
        leaf.getArguments(),
    );
    try leaf.getEntryBlock().addOperation(leaf_return.op);
    return module.op;
}
