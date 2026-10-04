const wasm = @import("../../../root.zig");
const ir = @import("../../../../../core/root.zig");
const dialects = @import("../../../../../dialects/root.zig");
const emission = @import("../../root.zig");
const instruction = @import("root.zig");

const FuncDialect = dialects.FuncDialect;

pub fn write(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
) emission.Error!void {
    const call = FuncDialect.CallOp{ .op = operation };
    const callee = call.getCallee() orelse return error.CodeGenFailed;
    const function_index = writer.plan.functionIndex(callee) orelse
        return error.FunctionNotFound;
    for (call.getOperands()) |operand| try writer.writeValue(operand);
    try writer.out.writeByte(0x10);
    try wasm.binary.writeUleb(writer.out, function_index);
    var index = call.getNumResults();
    while (index > 0) {
        index -= 1;
        const result = call.getResult(index) orelse return error.CodeGenFailed;
        try writer.writeLocalSet(try writer.localFor(result));
    }
}
