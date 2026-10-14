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
        try writeReceived(writer.out, result.type);
        try writer.writeLocalSet(try writer.localFor(result));
    }
}

/// A one-result call of the import at `function_index`, whose arguments are `operation`'s operands.
pub fn writeImport(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
    function_index: u32,
) emission.Error!void {
    for (operation.getOperandValues()) |operand| try writer.writeValue(operand);
    try writer.out.writeByte(0x10);
    try wasm.binary.writeUleb(writer.out, function_index);
    try writer.writeLocalSet(try writer.localFor(operation.getResult(0) orelse return error.CodeGenFailed));
}

/// The reader's half of the narrow-word rule, on the i32 the stack holds: a bool from its low
/// byte, and a narrow integer from its low declared-width bits, whatever the bits above hold.
pub fn writeReceived(out: anytype, typ: ir.Type) emission.Error!void {
    const scalar = emission.types.scalarKindForType(typ) orelse return;
    const mask: i64 = switch (scalar) {
        .bool, .u8 => 0xff,
        .u16 => 0xffff,
        .i8 => return out.writeByte(0xc0), // i32.extend8_s
        .i16 => return out.writeByte(0xc1), // i32.extend16_s
        else => return,
    };
    try out.writeByte(0x41);
    try wasm.binary.writeSleb(out, mask);
    try out.writeByte(0x71);
}
