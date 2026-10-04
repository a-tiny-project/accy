const wasm = @import("../../../root.zig");
const emission = @import("../../root.zig");
const common = @import("../root.zig").common;

pub fn write(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
) emission.Error!void {
    try common.writeSectionHeader(out, .function, plan.sections.function);
    try writeBody(out, plan, module);
}

pub fn countBody(
    plan: *const emission.Plan,
    module: *common.ir.Operation,
) emission.Error!usize {
    var count = wasm.binary.Count{};
    try writeBody(&count, plan, module);
    return common.requireU32(count.len);
}

fn writeBody(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
) emission.Error!void {
    _ = try common.requireU32(plan.definitionCount());
    try wasm.binary.writeUleb(out, plan.definitionCount());
    const module_op = try common.moduleOperation(module);
    var ordinal: usize = 0;
    var operations = module_op.getBodyBlock().getOperations();
    while (operations.next()) |operation| : (ordinal += 1) {
        const function = try common.functionOperation(operation);
        if (function.isDeclaration()) continue;
        _ = try common.requireU32(ordinal);
        try wasm.binary.writeUleb(out, ordinal);
    }
}
