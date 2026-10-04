const tensor = @import("../root.zig");
const trace = @import("root.zig");

const Builder = trace.Builder;
const CompareDirection = trace.CompareDirection;
const Dim = trace.Dim;
const Id = trace.Id;
const Reducer = trace.Reducer;
const Type = trace.Type;
const builder_mod = @import("builder.zig");
const type_mod = tensor.types;

pub const Value = struct {
    builder: *Builder,
    id: Id,
    ty: Type,

    pub fn add(self: Value, rhs: Value) !Value {
        return self.builder.alignedBinary(.add, self, rhs);
    }

    pub fn sub(self: Value, rhs: Value) !Value {
        return self.builder.alignedBinary(.sub, self, rhs);
    }

    pub fn mul(self: Value, rhs: Value) !Value {
        return self.builder.alignedBinary(.mul, self, rhs);
    }

    pub fn div(self: Value, rhs: Value) !Value {
        return self.builder.alignedBinary(.div, self, rhs);
    }

    pub fn pow(self: Value, rhs: Value) !Value {
        return self.builder.alignedBinary(.pow, self, rhs);
    }

    pub fn max(self: Value, other: anytype) !Value {
        if (comptime @TypeOf(other) == Value) {
            return self.builder.alignedBinary(.max, self, other);
        }
        return self.builder.reduceNamed(self, .max, valueAxes(other));
    }

    pub fn min(self: Value, other: anytype) !Value {
        if (comptime @TypeOf(other) == Value) {
            return self.builder.alignedBinary(.min, self, other);
        }
        return self.builder.reduceNamed(self, .min, valueAxes(other));
    }

    pub fn sum(self: Value, axes: anytype) !Value {
        return self.builder.reduceNamed(self, .sum, valueAxes(axes));
    }

    pub fn mean(self: Value, axes: anytype) !Value {
        return self.builder.meanNamed(self, valueAxes(axes));
    }

    pub fn reduce(self: Value, init: Value, reducer: Reducer, axes: anytype) !Value {
        return self.builder.reduceWith(self, init, reducer, valueAxes(axes));
    }

    pub fn gather(self: Value, indices: Value, comptime axis: anytype) !Value {
        return self.builder.gather(self, indices, axis);
    }

    pub fn scatterAdd(self: Value, indices: Value, updates: Value, comptime axis: anytype) !Value {
        return self.builder.scatterAdd(self, indices, updates, axis);
    }

    pub fn sparseCrossEntropyLoss(self: Value, targets: Value, comptime axis: anytype) !Value {
        return self.builder.sparseCrossEntropyLoss(self, targets, axis);
    }

    pub fn contract(self: Value, rhs: Value, axes: anytype) !Value {
        return self.builder.contract(self, rhs, valueAxes(axes));
    }

    pub fn rename(self: Value, comptime old_name: anytype, comptime new_name: anytype) !Value {
        return self.builder.renameAxis(
            self,
            comptime builder_mod.nameOf(old_name),
            comptime builder_mod.nameOf(new_name),
        );
    }

    pub fn split(self: Value, comptime axis: anytype, parts_struct: anytype) !Value {
        var buffer: [type_mod.dimCount(@TypeOf(parts_struct))]Dim = undefined;
        type_mod.fillDims(parts_struct, &buffer);
        return self.builder.splitAxis(self, comptime builder_mod.nameOf(axis), &buffer);
    }

    pub fn merge(self: Value, axes: anytype, comptime merged_name: anytype) !Value {
        return self.builder.mergeAxes(
            self,
            valueAxes(axes),
            comptime builder_mod.nameOf(merged_name),
        );
    }

    pub fn broadcast(self: Value, added_struct: anytype) !Value {
        var buffer: [type_mod.dimCount(@TypeOf(added_struct))]Dim = undefined;
        type_mod.fillDims(added_struct, &buffer);
        return self.builder.broadcastAxes(self, &buffer);
    }

    pub fn isStructuralZero(self: Value) bool {
        return self.builder.isStructuralZero(self.id);
    }

    pub fn neg(self: Value) !Value {
        return self.builder.unary(.neg, self);
    }

    pub fn abs(self: Value) !Value {
        return self.builder.unary(.abs, self);
    }

    pub fn exp(self: Value) !Value {
        return self.builder.unary(.exp, self);
    }

    pub fn log(self: Value) !Value {
        return self.builder.unary(.log, self);
    }

    pub fn sqrt(self: Value) !Value {
        return self.builder.unary(.sqrt, self);
    }

    pub fn tanh(self: Value) !Value {
        return self.builder.unary(.tanh, self);
    }

    pub fn sin(self: Value) !Value {
        return self.builder.unary(.sin, self);
    }

    pub fn cos(self: Value) !Value {
        return self.builder.unary(.cos, self);
    }

    pub fn tan(self: Value) !Value {
        return self.builder.unary(.tan, self);
    }

    pub fn compare(self: Value, direction: CompareDirection, rhs: Value) !Value {
        return self.builder.alignedCompare(direction, self, rhs);
    }

    pub fn select(self: Value, on_true: Value, on_false: Value) !Value {
        return self.builder.alignedSelect(self, on_true, on_false);
    }
};

fn valueAxes(axes: anytype) []const []const u8 {
    const Axes = @TypeOf(axes);
    if (comptime type_mod.isNameSlice(Axes)) {
        return axes;
    } else {
        return comptime type_mod.axisNames(axes);
    }
}
