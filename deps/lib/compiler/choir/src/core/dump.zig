const std = @import("std");
const alloc_arena = @import("alloc_arena");

const attribute = @import("attribute.zig");
const Attribute = attribute.Attribute;
const Block = @import("block.zig").Block;
const NamedAttribute = attribute.NamedAttribute;
const Operation = @import("operation/root.zig").Operation;
const Type = @import("type.zig").Type;
const Value = @import("value.zig").Value;

pub fn operationAlloc(allocator: std.mem.Allocator, op: *Operation) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeOperation(allocator, &out.writer, op);
    return try out.toOwnedSlice();
}

pub fn writeOperation(allocator: std.mem.Allocator, writer: *std.Io.Writer, op: *Operation) !void {
    var printer = Printer.init(allocator, writer);
    defer printer.deinit();
    try printer.writeOperation(op, 0);
}

const Printer = struct {
    writer: *std.Io.Writer,
    value_ids: std.AutoHashMap(*const Value, usize),
    next_value_id: usize = 0,

    fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) Printer {
        return .{
            .writer = writer,
            .value_ids = std.AutoHashMap(*const Value, usize).init(allocator),
        };
    }

    fn deinit(self: *Printer) void {
        self.value_ids.deinit();
    }

    fn writeOperation(self: *Printer, op: *Operation, indent: usize) anyerror!void {
        try self.writeIndent(indent);

        if (op.results.items.len > 0) {
            for (op.results.items, 0..) |*result, index| {
                if (index > 0) try self.writer.writeAll(", ");
                try self.writeValue(result);
            }
            try self.writer.writeAll(" = ");
        }

        try self.writer.writeAll(op.name.name);
        try self.writer.writeAll("(");
        for (op.operand_values, 0..) |operand, index| {
            if (index > 0) try self.writer.writeAll(", ");
            try self.writeValue(operand);
        }
        try self.writer.writeAll(")");

        if (op.successors.items.len > 0) {
            try self.writer.writeAll(" -> ");
            for (op.successors.items, 0..) |successor, index| {
                if (index > 0) try self.writer.writeAll(", ");
                try self.writer.print("^bb{d}", .{successor.id});
            }
        }

        if (try op.getPropertiesAsAttr()) |properties| {
            try self.writer.writeAll(" properties(");
            try self.writeAttribute(properties);
            try self.writer.writeAll(")");
        }

        try self.writeAttrs(op.getRawDictionaryAttrs());

        if (op.results.items.len > 0) {
            try self.writer.writeAll(" : ");
            for (op.results.items, 0..) |result, index| {
                if (index > 0) try self.writer.writeAll(", ");
                try self.writeType(result.type);
            }
        }

        if (op.regions.items.len == 0) {
            try self.writer.writeAll("\n");
            return;
        }

        for (op.regions.items) |*region| {
            try self.writer.writeAll(" ");
            try self.writer.writeAll("{\n");
            var block = region.blocks.head;
            while (block) |current| : (block = current.next) {
                const block_indent = indent + 1;
                try self.writeBlockHeader(current, block_indent);
                var ops = current.getOperations();
                while (ops.next()) |nested| {
                    try self.writeOperation(nested, block_indent + 1);
                }
            }
            try self.writeIndent(indent);
            try self.writer.writeAll("}");
        }
        try self.writer.writeAll("\n");
    }

    fn writeBlockHeader(self: *Printer, block: *Block, indent: usize) anyerror!void {
        try self.writeIndent(indent);
        try self.writer.print("^bb{d}", .{block.id});
        if (block.arguments.items.len > 0) {
            try self.writer.writeAll("(");
            for (block.arguments.items, 0..) |argument, index| {
                if (index > 0) try self.writer.writeAll(", ");
                try self.writeValue(argument);
                try self.writer.writeAll(": ");
                try self.writeType(argument.type);
            }
            try self.writer.writeAll(")");
        }
        try self.writer.writeAll(":\n");
    }

    fn writeAttrs(self: *Printer, attrs: []const NamedAttribute) anyerror!void {
        if (attrs.len == 0) return;
        try self.writer.writeAll(" {");
        for (attrs, 0..) |attr, index| {
            if (index > 0) try self.writer.writeAll(", ");
            try self.writeNamedAttr(attr);
        }
        try self.writer.writeAll("}");
    }

    fn writeNamedAttr(self: *Printer, attr: NamedAttribute) anyerror!void {
        try self.writer.print("{s} = ", .{attr.name});
        try self.writeAttribute(attr.value);
    }

    fn writeAttribute(self: *Printer, attr: Attribute) anyerror!void {
        if (attr.cast(Attribute.IntegerAttr)) |integer| {
            try self.writer.print("{d}:i{d}", .{ integer.value, integer.width });
            return;
        }
        if (attr.cast(Attribute.FloatAttr)) |float| {
            try self.writer.print("{d}:f{d}", .{ float.value, float.width });
            return;
        }
        if (attr.cast(Attribute.BoolAttr)) |bool_attr| {
            try self.writer.writeAll(if (bool_attr.value) "true" else "false");
            return;
        }
        if (attr.cast(Attribute.StringAttr)) |string| {
            try self.writeString(string.value);
            return;
        }
        if (attr.cast(Attribute.SymbolRefAttr)) |symbol| {
            try self.writer.print("@{s}", .{symbol.root_reference});
            for (symbol.nested_references) |nested| {
                try self.writer.print("::@{s}", .{nested});
            }
            return;
        }
        if (attr.cast(Attribute.StringListAttr)) |list| {
            try self.writer.writeAll("[");
            for (list.values, 0..) |value, index| {
                if (index > 0) try self.writer.writeAll(", ");
                try self.writeString(value);
            }
            try self.writer.writeAll("]");
            return;
        }
        if (attr.cast(Attribute.TypeListAttr)) |list| {
            try self.writer.writeAll("[");
            for (list.values, 0..) |typ, index| {
                if (index > 0) try self.writer.writeAll(", ");
                try self.writeType(typ);
            }
            try self.writer.writeAll("]");
            return;
        }
        if (attr.cast(Attribute.ArrayAttr)) |array| {
            try self.writer.writeAll("[");
            for (array.values, 0..) |value, index| {
                if (index > 0) try self.writer.writeAll(", ");
                try self.writeAttribute(value);
            }
            try self.writer.writeAll("]");
            return;
        }
        if (attr.cast(Attribute.DialectAttr)) |dialect| {
            try self.writer.print("#attr<{s}>", .{attr.abstract.name});
            if (dialect.payload.len > 0) {
                try self.writer.writeAll("(");
                try self.writeString(dialect.payload);
                try self.writer.writeAll(")");
            }
            return;
        }
        try self.writer.print("{f}", .{attr});
    }

    fn writeString(self: *Printer, value: []const u8) anyerror!void {
        try self.writer.writeByte('"');
        for (value) |byte| {
            switch (byte) {
                '"' => try self.writer.writeAll("\\\""),
                '\\' => try self.writer.writeAll("\\\\"),
                '\n' => try self.writer.writeAll("\\n"),
                '\r' => try self.writer.writeAll("\\r"),
                '\t' => try self.writer.writeAll("\\t"),
                else => try self.writer.writeByte(byte),
            }
        }
        try self.writer.writeByte('"');
    }

    fn writeType(self: *Printer, typ: Type) anyerror!void {
        try self.writer.print("{f}", .{typ});
    }

    fn writeValue(self: *Printer, value: *const Value) anyerror!void {
        const id = try self.valueId(value);
        try self.writer.print("%{d}", .{id});
    }

    fn valueId(self: *Printer, value: *const Value) anyerror!usize {
        if (self.value_ids.get(value)) |id| return id;
        const id = self.next_value_id;
        self.next_value_id += 1;
        try self.value_ids.put(value, id);
        return id;
    }

    fn writeIndent(self: *Printer, indent: usize) anyerror!void {
        for (0..indent) |_| try self.writer.writeAll("  ");
    }
};
