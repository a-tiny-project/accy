const std = @import("std");
const ir = @import("../../../core/root.zig");
const dialects = @import("../../../dialects/root.zig");
const emission = @import("root.zig");

const FuncDialect = dialects.FuncDialect;
const GlobalOp = dialects.MemrefDialect.GlobalOp;

/// The functions of a module body in order, past its `memref.global` declarations, which the
/// data layout places. Any other operation refuses.
pub const Functions = struct {
    operations: ir.Block.OperationIterator,

    pub fn init(module: *ir.Operation) emission.Error!Functions {
        if (!std.mem.eql(u8, module.name.name, dialects.BuiltinDialect.ModuleOp.operation_name)) {
            return error.CodeGenFailed;
        }
        const module_op = dialects.BuiltinDialect.ModuleOp{ .op = module };
        return .{ .operations = module_op.getBodyBlock().getOperations() };
    }

    pub fn next(self: *Functions) emission.Error!?FuncDialect.FuncOp {
        while (self.operations.next()) |operation| {
            const name = operation.name.name;
            if (std.mem.eql(u8, name, GlobalOp.operation_name)) continue;
            if (!std.mem.eql(u8, name, FuncDialect.FuncOp.operation_name)) return error.CodeGenFailed;
            return .{ .op = operation };
        }
        return null;
    }
};
