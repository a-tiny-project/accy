const std = @import("std");
const ir = @import("../../../core/root.zig");
const dialects = @import("../../../dialects/root.zig");
const emission = @import("root.zig");

const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;

pub const Role = enum {
    required,
    provided,
};

pub const Symbol = struct {
    name: []const u8,
    role: Role,
    function_ordinal: usize,
};

pub const Iterator = struct {
    operations: ir.Block.OperationIterator,
    options: emission.Options,
    function_ordinal: usize = 0,

    pub fn init(module: *ir.Operation, options: emission.Options) emission.Error!Iterator {
        if (!std.mem.eql(u8, module.name.name, BuiltinDialect.ModuleOp.operation_name)) {
            return error.CodeGenFailed;
        }
        const module_op = BuiltinDialect.ModuleOp{ .op = module };
        return .{
            .operations = module_op.getBodyBlock().getOperations(),
            .options = options,
        };
    }

    pub fn next(self: *Iterator) emission.Error!?Symbol {
        while (self.operations.next()) |operation| {
            const function_ordinal = self.function_ordinal;
            self.function_ordinal = std.math.add(
                usize,
                self.function_ordinal,
                1,
            ) catch return error.CapacityOverflow;
            if (!std.mem.eql(u8, operation.name.name, FuncDialect.FuncOp.operation_name)) {
                return error.CodeGenFailed;
            }
            const function = FuncDialect.FuncOp{ .op = operation };
            const name = function.getName() orelse return error.CodeGenFailed;
            if (function.isDeclaration()) {
                return .{
                    .name = name,
                    .role = .required,
                    .function_ordinal = function_ordinal,
                };
            }
            if (shouldExport(operation, name, self.options.entry)) {
                return .{
                    .name = name,
                    .role = .provided,
                    .function_ordinal = function_ordinal,
                };
            }
        }
        return null;
    }
};

fn shouldExport(
    operation: *ir.Operation,
    name: []const u8,
    entry: ?[]const u8,
) bool {
    if (entry) |requested| return std.mem.eql(u8, requested, name);
    return ir.SymbolTable.getSymbolVisibility(operation) == .public;
}
