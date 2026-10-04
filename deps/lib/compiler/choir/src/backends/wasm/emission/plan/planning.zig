const std = @import("std");
const ir = @import("../../../../core/root.zig");
const dialects = @import("../../../../dialects/root.zig");
const emission = @import("../root.zig");
const plan = @import("root.zig");

const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const MemrefDialect = dialects.MemrefDialect;
const types = emission.types;

pub fn fill(
    module: *ir.Operation,
    functions: []plan.FunctionPlan,
    function_index: []u32,
    values: []plan.ValuePlan,
    value_index: []u32,
    facts: emission.Facts,
) emission.Error!plan.Plan {
    if (!std.mem.eql(u8, module.name.name, BuiltinDialect.ModuleOp.operation_name)) {
        return error.CodeGenFailed;
    }
    if (!plan.index.storageIsValid(functions.len, function_index) or
        !plan.index.storageIsValid(values.len, value_index))
    {
        return error.InputChanged;
    }

    plan.index.clear(function_index);
    plan.index.clear(value_index);

    const result = plan.Plan{
        .functions = functions,
        .function_index = function_index,
        .values = values,
        .value_index = value_index,
        .import_count = facts.import_count,
        .definition_count = facts.definition_count,
        .needs_memory = facts.needs_memory,
        .sections = .{},
    };
    var function_cursor: usize = 0;
    var value_cursor: usize = 0;
    var local_count: usize = 0;
    var import_index: usize = 0;
    var definition_index = facts.import_count;
    var nesting_depth: usize = 0;
    var needs_memory = false;

    const module_op = BuiltinDialect.ModuleOp{ .op = module };
    var ops = module_op.getBodyBlock().getOperations();
    while (ops.next()) |op| {
        if (function_cursor == functions.len) return error.InputChanged;
        if (!std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) {
            return error.CodeGenFailed;
        }
        const func = FuncDialect.FuncOp{ .op = op };
        const name = func.getName() orelse return error.CodeGenFailed;
        needs_memory = needs_memory or typesNeedMemory(func.getInputTypes() orelse &.{}) or
            typesNeedMemory(func.getResultTypes());
        const imported = func.isDeclaration();
        const wasm_index = if (imported) index_value: {
            const value = try u32Index(import_index);
            import_index += 1;
            break :index_value value;
        } else index_value: {
            const value = try u32Index(definition_index);
            definition_index += 1;
            break :index_value value;
        };
        const function_plan = &functions[function_cursor];
        function_plan.* = .{
            .name = name,
            .value_start = try u32Index(value_cursor),
            .value_count = 0,
            .param_count = 0,
            .local_count = 0,
            .function_index = wasm_index,
            .body_bytes = 0,
        };
        try plan.index.insertFunction(function_index, functions, try u32Index(function_cursor));

        if (!imported) {
            const args = func.getArguments();
            function_plan.param_count = try u32Index(args.len);
            for (args, 0..) |argument, local_index| {
                try addValue(
                    result,
                    &value_cursor,
                    argument,
                    try u32Index(local_index),
                    &needs_memory,
                );
            }
            var next_local = function_plan.param_count;
            try addBlockValues(
                result,
                &value_cursor,
                func.getEntryBlock(),
                true,
                &next_local,
                &local_count,
                &nesting_depth,
                &needs_memory,
                0,
            );
            function_plan.local_count = next_local - function_plan.param_count;
            function_plan.value_count = next_local;
        }
        function_cursor += 1;
    }

    if (function_cursor != functions.len or
        value_cursor != values.len or
        local_count != facts.local_count or
        import_index != facts.import_count or
        definition_index != facts.import_count + facts.definition_count or
        nesting_depth != facts.nesting_depth or
        needs_memory != facts.needs_memory)
    {
        return error.InputChanged;
    }

    return result;
}

fn addBlockValues(
    result: plan.Plan,
    cursor: *usize,
    block: *ir.Block,
    skip_arguments: bool,
    next_local: *u32,
    local_count: *usize,
    nesting_depth: *usize,
    needs_memory: *bool,
    depth: usize,
) emission.Error!void {
    if (depth > emission.max_nesting_depth) return error.NestingLimitExceeded;
    nesting_depth.* = @max(nesting_depth.*, depth);
    if (!skip_arguments) {
        local_count.* = std.math.add(
            usize,
            local_count.*,
            block.arguments.items.len,
        ) catch return error.CapacityOverflow;
        for (block.arguments.items) |argument| {
            try addValue(result, cursor, argument, next_local.*, needs_memory);
            next_local.* = std.math.add(u32, next_local.*, 1) catch
                return error.CapacityOverflow;
        }
    }

    var ops = block.getOperations();
    while (ops.next()) |op| {
        local_count.* = std.math.add(
            usize,
            local_count.*,
            op.results.items.len,
        ) catch return error.CapacityOverflow;
        for (op.results.items) |*value| {
            try addValue(result, cursor, value, next_local.*, needs_memory);
            next_local.* = std.math.add(u32, next_local.*, 1) catch
                return error.CapacityOverflow;
        }
        if (std.mem.eql(u8, op.name.name, MemrefDialect.LoadOp.operation_name) or
            std.mem.eql(u8, op.name.name, MemrefDialect.StoreOp.operation_name))
        {
            needs_memory.* = true;
        }
        for (op.regions.items) |*region| {
            if (region.blocks.size != 1) return error.InputChanged;
            const entry = region.getEntryBlock() orelse return error.CodeGenFailed;
            try addBlockValues(
                result,
                cursor,
                entry,
                false,
                next_local,
                local_count,
                nesting_depth,
                needs_memory,
                depth + 1,
            );
        }
    }
}

fn addValue(
    result: plan.Plan,
    cursor: *usize,
    value: *ir.Value,
    local_index: u32,
    needs_memory: *bool,
) emission.Error!void {
    if (cursor.* == result.values.len) return error.InputChanged;
    result.values[cursor.*] = .{
        .value = value,
        .local_index = local_index,
        .value_type = try types.wasmTypeForType(value.type),
    };
    if (types.typeIsMemref(value.type)) needs_memory.* = true;
    try plan.index.insertValue(result.value_index, result.values, try u32Index(cursor.*));
    cursor.* += 1;
}

fn typesNeedMemory(value_types: []const ir.Type) bool {
    for (value_types) |typ| {
        if (types.typeIsMemref(typ)) return true;
    }
    return false;
}

fn u32Index(value: usize) emission.Error!u32 {
    return std.math.cast(u32, value) orelse error.CapacityOverflow;
}
