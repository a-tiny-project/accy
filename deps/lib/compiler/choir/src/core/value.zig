const std = @import("std");
const Type = @import("type.zig").Type;

pub const Value = struct {
    kind: Kind,

    type: Type,

    id: u32,

    first_use: ?*OpOperand = null,

    pub const Kind = union(enum) {
        block_argument: BlockArgumentInfo,

        op_result: OpResultInfo,
    };

    pub const BlockArgumentInfo = struct {
        owner: *anyopaque,
        arg_number: u32,
    };

    pub const OpResultInfo = struct {
        owner: *anyopaque,
        result_number: u32,
    };

    pub fn isBlockArgument(self: Value) bool {
        return self.kind == .block_argument;
    }

    pub fn isOpResult(self: Value) bool {
        return self.kind == .op_result;
    }

    pub fn getDefiningOp(self: Value) ?*anyopaque {
        return switch (self.kind) {
            .op_result => |info| info.owner,
            .block_argument => null,
        };
    }

    pub fn getOwnerBlock(self: Value) ?*anyopaque {
        return switch (self.kind) {
            .block_argument => |info| info.owner,
            .op_result => null,
        };
    }

    pub fn hasNoUses(self: Value) bool {
        return self.first_use == null;
    }

    pub fn hasOneUse(self: Value) bool {
        const first = self.first_use orelse return false;
        return first.next_use == null;
    }

    pub fn getNumUses(self: Value) usize {
        var count: usize = 0;
        var use = self.first_use;
        while (use) |u| {
            count += 1;
            use = u.next_use;
        }
        return count;
    }

    pub fn useIterator(self: *Value) UseIterator {
        return .{ .current = self.first_use };
    }

    pub fn addUse(self: *Value, operand: *OpOperand) void {
        operand.next_use = self.first_use;
        if (self.first_use) |first| {
            first.back = &operand.next_use;
        }
        self.first_use = operand;
        operand.back = &self.first_use;
    }

    pub fn dropAllUses(self: *Value) void {
        while (self.first_use) |op_operand| {
            op_operand.detach();
        }
    }

    pub fn replaceAllUsesWith(self: *Value, replacement: *Value) void {
        if (self == replacement) return;
        var uses = self.useIterator();
        while (uses.next()) |op_operand| {
            op_operand.setValue(replacement);
        }
    }

    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("%{d}", .{self.id});
    }
};

pub const UseIterator = struct {
    current: ?*OpOperand,

    pub fn next(self: *UseIterator) ?*OpOperand {
        const current = self.current orelse return null;
        self.current = current.next_use;
        return current;
    }
};

pub const OpOperand = struct {
    value: *Value,

    owner: *anyopaque,

    operand_number: u32,

    operand_value_slot: ?**Value,

    next_use: ?*OpOperand,

    back: ?*?*OpOperand = null,

    pub fn attach(self: *OpOperand) void {
        self.value.addUse(self);
    }

    pub fn detach(self: *OpOperand) void {
        const back = self.back orelse return;
        back.* = self.next_use;
        if (self.next_use) |next| {
            next.back = back;
        }
        self.back = null;
        self.next_use = null;
    }

    pub fn setValue(self: *OpOperand, new_value: *Value) void {
        if (self.value == new_value) return;
        self.detach();
        self.value = new_value;
        self.attach();
        if (self.operand_value_slot) |slot| {
            slot.* = new_value;
        }
    }
};
