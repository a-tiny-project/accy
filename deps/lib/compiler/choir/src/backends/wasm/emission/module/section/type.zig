const wasm = @import("../../../root.zig");
const emission = @import("../../root.zig");
const common = @import("../root.zig").common;

pub fn write(
    out: anytype,
    plan: *const emission.Plan,
    module: *common.ir.Operation,
) emission.Error!void {
    try common.writeSectionHeader(out, .type, plan.sections.type);
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
    _ = try common.requireU32(plan.functionCount());
    try wasm.binary.writeUleb(out, plan.functionCount());
    const module_op = try common.moduleOperation(module);
    var operations = module_op.getBodyBlock().getOperations();
    while (operations.next()) |operation| {
        const function = try common.functionOperation(operation);
        try out.writeByte(0x60);
        try common.writeTypeVector(out, function.getInputTypes() orelse &.{});
        try common.writeTypeVector(out, function.getResultTypes());
    }
}
