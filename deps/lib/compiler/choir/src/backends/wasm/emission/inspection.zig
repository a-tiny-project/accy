const std = @import("std");
const ir = @import("../../../core/root.zig");
const dialects = @import("../../../dialects/root.zig");
const emission = @import("root.zig");

const BuiltinDialect = dialects.BuiltinDialect;
const MemrefDialect = dialects.MemrefDialect;
const types = emission.types;

pub fn inspect(module: *ir.Operation, options: emission.Options) emission.Error!emission.Facts {
    if (!std.mem.eql(u8, module.name.name, BuiltinDialect.ModuleOp.operation_name)) {
        return error.CodeGenFailed;
    }

    var facts = emission.Facts{
        .function_count = 0,
        .import_count = 0,
        .definition_count = 0,
        .value_count = 0,
        .local_count = 0,
        .nesting_depth = 0,
        .needs_memory = false,
    };

    var functions = try emission.walk.Functions.init(module);
    while (try functions.next()) |func| {
        _ = func.getName() orelse return error.CodeGenFailed;
        facts.function_count = try addCount(facts.function_count, 1);
        const inputs = func.getInputTypes() orelse &.{};
        try inspectTypes(inputs, &facts.needs_memory);
        try inspectTypes(func.getResultTypes(), &facts.needs_memory);
        if (func.isDeclaration()) {
            facts.import_count = try addCount(facts.import_count, 1);
            continue;
        }

        facts.definition_count = try addCount(facts.definition_count, 1);
        const args = func.getArguments();
        facts.value_count = try addCount(facts.value_count, args.len);
        for (args) |argument| _ = try types.wasmTypeForType(argument.type);
        try inspectBlock(func.getEntryBlock(), true, 0, &facts);
    }

    facts.data = try emission.data.layout(module);
    if (facts.data.globals != 0) facts.needs_memory = true;
    try requireU32(facts.function_count);
    try requireU32(facts.import_count);
    try requireU32(facts.definition_count);
    try requireU32(facts.value_count);
    try requireU32(facts.local_count);
    if (options.entry != null) {
        var symbols = try emission.symbols.Iterator.init(module, options);
        var found = false;
        while (try symbols.next()) |symbol| {
            if (symbol.role == .provided) {
                found = true;
                break;
            }
        }
        if (!found) return error.FunctionNotFound;
    }
    return facts;
}

fn inspectBlock(
    block: *ir.Block,
    skip_arguments: bool,
    depth: usize,
    facts: *emission.Facts,
) emission.Error!void {
    if (depth > emission.max_nesting_depth) return error.NestingLimitExceeded;
    facts.nesting_depth = @max(facts.nesting_depth, depth);
    if (!skip_arguments) {
        facts.value_count = try addCount(facts.value_count, block.arguments.items.len);
        facts.local_count = try addCount(facts.local_count, block.arguments.items.len);
        for (block.arguments.items) |argument| _ = try types.wasmTypeForType(argument.type);
    }

    var ops = block.getOperations();
    while (ops.next()) |operation| {
        facts.value_count = try addCount(facts.value_count, operation.results.items.len);
        facts.local_count = try addCount(facts.local_count, operation.results.items.len);
        for (operation.results.items) |result| _ = try types.wasmTypeForType(result.type);
        if (emission.math.classify(operation)) |function| facts.math.add(function);
        if (std.mem.eql(u8, operation.name.name, MemrefDialect.LoadOp.operation_name) or
            std.mem.eql(u8, operation.name.name, MemrefDialect.StoreOp.operation_name))
        {
            facts.needs_memory = true;
        }
        for (operation.regions.items) |*region| {
            if (region.blocks.size != 1) return error.CodeGenFailed;
            const entry = region.getEntryBlock() orelse return error.CodeGenFailed;
            try inspectBlock(entry, false, depth + 1, facts);
        }
    }
}

fn inspectTypes(value_types: []const ir.Type, needs_memory: *bool) emission.Error!void {
    try requireU32(value_types.len);
    for (value_types) |typ| {
        _ = try types.wasmTypeForType(typ);
        if (types.typeIsMemref(typ)) needs_memory.* = true;
    }
}

fn addCount(lhs: usize, rhs: usize) emission.Error!usize {
    return std.math.add(usize, lhs, rhs) catch error.CapacityOverflow;
}

fn requireU32(value: usize) emission.Error!void {
    if (value > std.math.maxInt(u32)) return error.CapacityOverflow;
}
