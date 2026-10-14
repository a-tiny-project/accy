const std = @import("std");
const ir = @import("../../../core/root.zig");
const emission = @import("root.zig");

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
    functions: emission.walk.Functions,
    options: emission.Options,
    function_ordinal: usize = 0,

    pub fn init(module: *ir.Operation, options: emission.Options) emission.Error!Iterator {
        return .{ .functions = try emission.walk.Functions.init(module), .options = options };
    }

    pub fn next(self: *Iterator) emission.Error!?Symbol {
        while (try self.functions.next()) |function| {
            const function_ordinal = self.function_ordinal;
            self.function_ordinal = std.math.add(
                usize,
                self.function_ordinal,
                1,
            ) catch return error.CapacityOverflow;
            const operation = function.op;
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
