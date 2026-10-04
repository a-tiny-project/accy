const std = @import("std");
const memory = @import("memory.zig");
const tag = @import("tag.zig");

const Window = struct {
    lane_start: usize,
    storage_start: usize,
    count: usize,
};

pub fn UnrollerUnit(comptime InputLane: type, comptime OutputLane: type) type {
    validateLane(InputLane);
    validateLane(OutputLane);
    const LargerLane = signedLane(@max(@sizeOf(InputLane), @sizeOf(OutputLane)));
    const LargerTag = tag.ScalableTag(LargerLane);

    return struct {
        pub const input_count: usize = 1;
        pub const Input: type = InputLane;
        pub const Output: type = OutputLane;
        pub const Larger: type = LargerLane;
        pub const Tag: type = LargerTag;
        pub const InputTag: type = LargerTag.rebind(InputLane);
        pub const OutputTag: type = LargerTag.rebind(OutputLane);
        pub const InputVector: type = InputTag.Vector;
        pub const OutputVector: type = OutputTag.Vector;
        pub const XVector: type = InputVector;
        pub const YVector: type = OutputVector;
        pub const max_unit_lanes: usize = LargerTag.lane_count;
        pub const actual_lanes: usize = LargerTag.lane_count;

        pub fn maxUnitLanes() usize {
            return max_unit_lanes;
        }

        pub fn actualLanes() usize {
            return actual_lanes;
        }

        pub fn x0Init() InputVector {
            return @splat(0);
        }

        pub fn yInit() OutputVector {
            return @splat(0);
        }

        pub fn load(index: isize, input: []const Input) InputVector {
            return loadFull(InputTag, index, input);
        }

        pub fn maskLoad(index: isize, input: []const Input, places: isize) InputVector {
            return maskLoadOr(@splat(0), index, input, places);
        }

        pub fn maskLoadOr(
            inactive: InputVector,
            index: isize,
            input: []const Input,
            places: isize,
        ) InputVector {
            return loadPartial(InputTag, inactive, index, input, places);
        }

        pub fn storeAndShortCircuit(
            index: isize,
            output: []Output,
            value: OutputVector,
        ) bool {
            storeFull(OutputTag, index, output, value);
            return true;
        }

        pub fn maskStore(
            index: isize,
            output: []Output,
            value: OutputVector,
            places: isize,
        ) usize {
            return storePartial(OutputTag, index, output, value, places);
        }

        pub fn reduceFinal(_: OutputVector, _: []Output) usize {
            return 0;
        }

        pub fn reduceUnrolled(
            _: OutputVector,
            _: OutputVector,
            _: OutputVector,
            value: OutputVector,
        ) OutputVector {
            return value;
        }
    };
}

pub fn UnrollerUnit2D(
    comptime Input0Lane: type,
    comptime Input1Lane: type,
    comptime OutputLane: type,
) type {
    validateLane(Input0Lane);
    validateLane(Input1Lane);
    validateLane(OutputLane);
    const LargerLane = signedLane(@max(
        @sizeOf(Input0Lane),
        @max(@sizeOf(Input1Lane), @sizeOf(OutputLane)),
    ));
    const LargerTag = tag.ScalableTag(LargerLane);

    return struct {
        pub const input_count: usize = 2;
        pub const Input0: type = Input0Lane;
        pub const Input1: type = Input1Lane;
        pub const Output: type = OutputLane;
        pub const Larger: type = LargerLane;
        pub const Tag: type = LargerTag;
        pub const Input0Tag: type = LargerTag.rebind(Input0Lane);
        pub const Input1Tag: type = LargerTag.rebind(Input1Lane);
        pub const OutputTag: type = LargerTag.rebind(OutputLane);
        pub const Input0Vector: type = Input0Tag.Vector;
        pub const Input1Vector: type = Input1Tag.Vector;
        pub const OutputVector: type = OutputTag.Vector;
        pub const X0Vector: type = Input0Vector;
        pub const X1Vector: type = Input1Vector;
        pub const YVector: type = OutputVector;
        pub const max_unit_lanes: usize = LargerTag.lane_count;
        pub const actual_lanes: usize = LargerTag.lane_count;

        pub fn maxUnitLanes() usize {
            return max_unit_lanes;
        }

        pub fn actualLanes() usize {
            return actual_lanes;
        }

        pub fn x0Init() Input0Vector {
            return @splat(0);
        }

        pub fn x1Init() Input1Vector {
            return @splat(0);
        }

        pub fn yInit() OutputVector {
            return @splat(0);
        }

        pub fn load0(index: isize, input: []const Input0) Input0Vector {
            return loadFull(Input0Tag, index, input);
        }

        pub fn load1(index: isize, input: []const Input1) Input1Vector {
            return loadFull(Input1Tag, index, input);
        }

        pub fn maskLoad0(
            index: isize,
            input: []const Input0,
            places: isize,
        ) Input0Vector {
            return maskLoad0Or(@splat(0), index, input, places);
        }

        pub fn maskLoad0Or(
            inactive: Input0Vector,
            index: isize,
            input: []const Input0,
            places: isize,
        ) Input0Vector {
            return loadPartial(Input0Tag, inactive, index, input, places);
        }

        pub fn maskLoad1(
            index: isize,
            input: []const Input1,
            places: isize,
        ) Input1Vector {
            return maskLoad1Or(@splat(0), index, input, places);
        }

        pub fn maskLoad1Or(
            inactive: Input1Vector,
            index: isize,
            input: []const Input1,
            places: isize,
        ) Input1Vector {
            return loadPartial(Input1Tag, inactive, index, input, places);
        }

        pub fn storeAndShortCircuit(
            index: isize,
            output: []Output,
            value: OutputVector,
        ) bool {
            storeFull(OutputTag, index, output, value);
            return true;
        }

        pub fn maskStore(
            index: isize,
            output: []Output,
            value: OutputVector,
            places: isize,
        ) usize {
            return storePartial(OutputTag, index, output, value, places);
        }

        pub fn reduceFinal(_: OutputVector, _: []Output) usize {
            return 0;
        }

        pub fn reduceUnrolled(
            _: OutputVector,
            _: OutputVector,
            _: OutputVector,
            value: OutputVector,
        ) OutputVector {
            return value;
        }
    };
}

pub fn unroll(unit: anytype, input: anytype, output: anytype) void {
    const Unit = pointee(@TypeOf(unit));
    const Base = unitBase(Unit, 1);
    if (!@hasDecl(Unit, "func")) @compileError("unroller unit must declare func");
    const input_slice: []const Base.Input = input;
    const output_slice: []Base.Output = output;
    const lane_count = Base.actual_lanes;
    std.debug.assert(input_slice.len <= std.math.maxInt(isize));

    var x0 = x0Init(Unit, Base, unit);
    var y = yInit(Unit, Base, unit);
    var index: usize = 0;

    if (input_slice.len < lane_count) {
        const count: isize = @intCast(input_slice.len);
        x0 = maskLoad(Unit, Base, unit, 0, input_slice, count);
        y = unit.func(0, x0, y);
        _ = maskStore(Unit, Base, unit, 0, output_slice, y, count);
        _ = reduceFinal(Unit, Base, unit, y, output_slice);
        return;
    }

    if (input_slice.len > 4 * lane_count) {
        var x01 = x0Init(Unit, Base, unit);
        var y1 = yInit(Unit, Base, unit);
        var x02 = x0Init(Unit, Base, unit);
        var y2 = yInit(Unit, Base, unit);
        var x03 = x0Init(Unit, Base, unit);
        var y3 = yInit(Unit, Base, unit);

        while (index + 4 * lane_count <= input_slice.len) {
            x0 = load(Unit, Base, unit, @intCast(index), input_slice);
            x01 = load(Unit, Base, unit, @intCast(index + lane_count), input_slice);
            x02 = load(Unit, Base, unit, @intCast(index + 2 * lane_count), input_slice);
            x03 = load(Unit, Base, unit, @intCast(index + 3 * lane_count), input_slice);

            y = unit.func(@intCast(index), x0, y);
            y1 = unit.func(@intCast(index + lane_count), x01, y1);
            y2 = unit.func(@intCast(index + 2 * lane_count), x02, y2);
            y3 = unit.func(@intCast(index + 3 * lane_count), x03, y3);

            if (!storeAndShortCircuit(Unit, Base, unit, @intCast(index), output_slice, y)) return;
            index += lane_count;
            if (!storeAndShortCircuit(Unit, Base, unit, @intCast(index), output_slice, y1)) return;
            index += lane_count;
            if (!storeAndShortCircuit(Unit, Base, unit, @intCast(index), output_slice, y2)) return;
            index += lane_count;
            if (!storeAndShortCircuit(Unit, Base, unit, @intCast(index), output_slice, y3)) return;
            index += lane_count;
        }

        y = reduceUnrolled(Unit, Base, unit, y3, y2, y1, y);
    }

    while (index + lane_count <= input_slice.len) : (index += lane_count) {
        x0 = load(Unit, Base, unit, @intCast(index), input_slice);
        y = unit.func(@intCast(index), x0, y);
        if (!storeAndShortCircuit(Unit, Base, unit, @intCast(index), output_slice, y)) return;
    }

    if (index != input_slice.len) {
        const tail_index = input_slice.len - lane_count;
        const places = @as(isize, @intCast(index)) - @as(isize, @intCast(input_slice.len));
        x0 = maskLoad(Unit, Base, unit, @intCast(tail_index), input_slice, places);
        y = unit.func(@intCast(tail_index), x0, y);
        _ = maskStore(Unit, Base, unit, @intCast(tail_index), output_slice, y, places);
    }

    _ = reduceFinal(Unit, Base, unit, y, output_slice);
}

pub fn unroll2(unit: anytype, input0: anytype, input1: anytype, output: anytype) void {
    const Unit = pointee(@TypeOf(unit));
    const Base = unitBase(Unit, 2);
    if (!@hasDecl(Unit, "func")) @compileError("two-input unroller unit must declare func");
    const input0_slice: []const Base.Input0 = input0;
    const input1_slice: []const Base.Input1 = input1;
    const output_slice: []Base.Output = output;
    const lane_count = Base.actual_lanes;
    std.debug.assert(input0_slice.len == input1_slice.len);
    std.debug.assert(input0_slice.len <= std.math.maxInt(isize));

    var x0 = x0Init2(Unit, Base, unit);
    var x1 = x1Init2(Unit, Base, unit);
    var y = yInit(Unit, Base, unit);
    var index: usize = 0;

    if (input0_slice.len < lane_count) {
        const count: isize = @intCast(input0_slice.len);
        x0 = maskLoad0(Unit, Base, unit, 0, input0_slice, count);
        x1 = maskLoad1(Unit, Base, unit, 0, input1_slice, count);
        y = unit.func(0, x0, x1, y);
        _ = maskStore(Unit, Base, unit, 0, output_slice, y, count);
        _ = reduceFinal(Unit, Base, unit, y, output_slice);
        return;
    }

    if (input0_slice.len > 4 * lane_count) {
        var x01 = x0Init2(Unit, Base, unit);
        var x11 = x1Init2(Unit, Base, unit);
        var y1 = yInit(Unit, Base, unit);
        var x02 = x0Init2(Unit, Base, unit);
        var x12 = x1Init2(Unit, Base, unit);
        var y2 = yInit(Unit, Base, unit);
        var x03 = x0Init2(Unit, Base, unit);
        var x13 = x1Init2(Unit, Base, unit);
        var y3 = yInit(Unit, Base, unit);

        while (index + 4 * lane_count <= input0_slice.len) {
            x0 = load0(Unit, Base, unit, @intCast(index), input0_slice);
            x1 = load1(Unit, Base, unit, @intCast(index), input1_slice);
            x01 = load0(Unit, Base, unit, @intCast(index + lane_count), input0_slice);
            x11 = load1(Unit, Base, unit, @intCast(index + lane_count), input1_slice);
            x02 = load0(Unit, Base, unit, @intCast(index + 2 * lane_count), input0_slice);
            x12 = load1(Unit, Base, unit, @intCast(index + 2 * lane_count), input1_slice);
            x03 = load0(Unit, Base, unit, @intCast(index + 3 * lane_count), input0_slice);
            x13 = load1(Unit, Base, unit, @intCast(index + 3 * lane_count), input1_slice);

            y = unit.func(@intCast(index), x0, x1, y);
            y1 = unit.func(@intCast(index + lane_count), x01, x11, y1);
            y2 = unit.func(@intCast(index + 2 * lane_count), x02, x12, y2);
            y3 = unit.func(@intCast(index + 3 * lane_count), x03, x13, y3);

            if (!storeAndShortCircuit(Unit, Base, unit, @intCast(index), output_slice, y)) return;
            index += lane_count;
            if (!storeAndShortCircuit(Unit, Base, unit, @intCast(index), output_slice, y1)) return;
            index += lane_count;
            if (!storeAndShortCircuit(Unit, Base, unit, @intCast(index), output_slice, y2)) return;
            index += lane_count;
            if (!storeAndShortCircuit(Unit, Base, unit, @intCast(index), output_slice, y3)) return;
            index += lane_count;
        }

        y = reduceUnrolled(Unit, Base, unit, y3, y2, y1, y);
    }

    while (index + lane_count <= input0_slice.len) : (index += lane_count) {
        x0 = load0(Unit, Base, unit, @intCast(index), input0_slice);
        x1 = load1(Unit, Base, unit, @intCast(index), input1_slice);
        y = unit.func(@intCast(index), x0, x1, y);
        if (!storeAndShortCircuit(Unit, Base, unit, @intCast(index), output_slice, y)) return;
    }

    if (index != input0_slice.len) {
        const tail_index = input0_slice.len - lane_count;
        const places = @as(isize, @intCast(index)) - @as(isize, @intCast(input0_slice.len));
        x0 = maskLoad0(Unit, Base, unit, @intCast(tail_index), input0_slice, places);
        x1 = maskLoad1(Unit, Base, unit, @intCast(tail_index), input1_slice, places);
        y = unit.func(@intCast(tail_index), x0, x1, y);
        _ = maskStore(Unit, Base, unit, @intCast(tail_index), output_slice, y, places);
    }

    _ = reduceFinal(Unit, Base, unit, y, output_slice);
}

fn x0Init(comptime Unit: type, comptime Base: type, unit: anytype) Base.InputVector {
    if (comptime @hasDecl(Unit, "x0Init")) return unit.x0Init();
    return Base.x0Init();
}

fn x0Init2(comptime Unit: type, comptime Base: type, unit: anytype) Base.Input0Vector {
    if (comptime @hasDecl(Unit, "x0Init")) return unit.x0Init();
    return Base.x0Init();
}

fn x1Init2(comptime Unit: type, comptime Base: type, unit: anytype) Base.Input1Vector {
    if (comptime @hasDecl(Unit, "x1Init")) return unit.x1Init();
    return Base.x1Init();
}

fn yInit(comptime Unit: type, comptime Base: type, unit: anytype) Base.OutputVector {
    if (comptime @hasDecl(Unit, "yInit")) return unit.yInit();
    return Base.yInit();
}

fn load(
    comptime Unit: type,
    comptime Base: type,
    unit: anytype,
    index: isize,
    input: []const Base.Input,
) Base.InputVector {
    if (comptime @hasDecl(Unit, "load")) return unit.load(index, input);
    return Base.load(index, input);
}

fn load0(
    comptime Unit: type,
    comptime Base: type,
    unit: anytype,
    index: isize,
    input: []const Base.Input0,
) Base.Input0Vector {
    if (comptime @hasDecl(Unit, "load0")) return unit.load0(index, input);
    return Base.load0(index, input);
}

fn load1(
    comptime Unit: type,
    comptime Base: type,
    unit: anytype,
    index: isize,
    input: []const Base.Input1,
) Base.Input1Vector {
    if (comptime @hasDecl(Unit, "load1")) return unit.load1(index, input);
    return Base.load1(index, input);
}

fn maskLoad(
    comptime Unit: type,
    comptime Base: type,
    unit: anytype,
    index: isize,
    input: []const Base.Input,
    places: isize,
) Base.InputVector {
    if (comptime @hasDecl(Unit, "maskLoad")) return unit.maskLoad(index, input, places);
    return Base.maskLoad(index, input, places);
}

fn maskLoad0(
    comptime Unit: type,
    comptime Base: type,
    unit: anytype,
    index: isize,
    input: []const Base.Input0,
    places: isize,
) Base.Input0Vector {
    if (comptime @hasDecl(Unit, "maskLoad0")) return unit.maskLoad0(index, input, places);
    return Base.maskLoad0(index, input, places);
}

fn maskLoad1(
    comptime Unit: type,
    comptime Base: type,
    unit: anytype,
    index: isize,
    input: []const Base.Input1,
    places: isize,
) Base.Input1Vector {
    if (comptime @hasDecl(Unit, "maskLoad1")) return unit.maskLoad1(index, input, places);
    return Base.maskLoad1(index, input, places);
}

fn storeAndShortCircuit(
    comptime Unit: type,
    comptime Base: type,
    unit: anytype,
    index: isize,
    output: []Base.Output,
    value: Base.OutputVector,
) bool {
    if (comptime @hasDecl(Unit, "storeAndShortCircuit")) {
        return unit.storeAndShortCircuit(index, output, value);
    }
    return Base.storeAndShortCircuit(index, output, value);
}

fn maskStore(
    comptime Unit: type,
    comptime Base: type,
    unit: anytype,
    index: isize,
    output: []Base.Output,
    value: Base.OutputVector,
    places: isize,
) usize {
    if (comptime @hasDecl(Unit, "maskStore")) {
        return unit.maskStore(index, output, value, places);
    }
    return Base.maskStore(index, output, value, places);
}

fn reduceFinal(
    comptime Unit: type,
    comptime Base: type,
    unit: anytype,
    value: Base.OutputVector,
    output: []Base.Output,
) usize {
    if (comptime @hasDecl(Unit, "reduceFinal")) return unit.reduceFinal(value, output);
    return Base.reduceFinal(value, output);
}

fn reduceUnrolled(
    comptime Unit: type,
    comptime Base: type,
    unit: anytype,
    x0: Base.OutputVector,
    x1: Base.OutputVector,
    x2: Base.OutputVector,
    value: Base.OutputVector,
) Base.OutputVector {
    if (comptime @hasDecl(Unit, "reduceUnrolled")) {
        return unit.reduceUnrolled(x0, x1, x2, value);
    }
    return Base.reduceUnrolled(x0, x1, x2, value);
}

fn loadFull(comptime D: type, index: isize, input: []const D.Lane) D.Vector {
    std.debug.assert(index >= 0);
    const start: usize = @intCast(index);
    std.debug.assert(start <= input.len);
    std.debug.assert(D.lane_count <= input.len - start);
    return memory.load(D, input[start..]);
}

fn loadPartial(
    comptime D: type,
    inactive: D.Vector,
    index: isize,
    input: []const D.Lane,
    places: isize,
) D.Vector {
    const selected = window(D.lane_count, index, places, input.len);
    var lanes: [D.lane_count]D.Lane = inactive;
    for (0..selected.count) |offset| {
        lanes[selected.lane_start + offset] = input[selected.storage_start + offset];
    }
    return lanes;
}

fn storeFull(
    comptime D: type,
    index: isize,
    output: []D.Lane,
    value: D.Vector,
) void {
    std.debug.assert(index >= 0);
    const start: usize = @intCast(index);
    std.debug.assert(start <= output.len);
    std.debug.assert(D.lane_count <= output.len - start);
    memory.store(D, value, output[start..]);
}

fn storePartial(
    comptime D: type,
    index: isize,
    output: []D.Lane,
    value: D.Vector,
    places: isize,
) usize {
    const selected = window(D.lane_count, index, places, output.len);
    const lanes: [D.lane_count]D.Lane = value;
    for (0..selected.count) |offset| {
        output[selected.storage_start + offset] = lanes[selected.lane_start + offset];
    }
    return selected.count;
}

fn window(lane_count: usize, index: isize, places: isize, length: usize) Window {
    const bound: isize = @intCast(lane_count);
    std.debug.assert(places >= -bound);
    std.debug.assert(places <= bound);
    const count: usize = @intCast(if (places < 0) -places else places);
    const lane_start = if (places < 0) lane_count - count else 0;
    const lane_offset: isize = @intCast(lane_start);
    std.debug.assert(index <= std.math.maxInt(isize) - lane_offset);
    const storage_index = index + lane_offset;
    std.debug.assert(storage_index >= 0);
    const storage_start: usize = @intCast(storage_index);
    std.debug.assert(storage_start <= length);
    std.debug.assert(count <= length - storage_start);
    return .{
        .lane_start = lane_start,
        .storage_start = storage_start,
        .count = count,
    };
}

fn pointee(comptime Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |info| if (info.size == .one)
            info.child
        else
            @compileError("unroller unit must be passed by single-item pointer"),
        else => @compileError("unroller unit must be passed by pointer"),
    };
}

fn unitBase(comptime Unit: type, comptime input_count: usize) type {
    if (!@hasDecl(Unit, "Base")) {
        @compileError("unroller unit must declare Base = UnrollerUnit(...) or UnrollerUnit2D(...)");
    }
    const Base = Unit.Base;
    if (!@hasDecl(Base, "input_count") or Base.input_count != input_count) {
        @compileError("unroller unit Base has the wrong input count");
    }
    return Base;
}

fn validateLane(comptime T: type) void {
    if (!tag.isLane(T)) @compileError("unroller units require SIMD lane types");
}

fn signedLane(comptime byte_count: usize) type {
    return switch (byte_count) {
        1 => i8,
        2 => i16,
        4 => i32,
        8 => i64,
        else => @compileError("unroller lane sizes must be 1, 2, 4, or 8 bytes"),
    };
}

fn MultiplyUnit(comptime T: type) type {
    const UnitBase = UnrollerUnit2D(T, T, T);
    return struct {
        pub const Base: type = UnitBase;

        pub fn func(
            _: *@This(),
            _: isize,
            x0: Base.Input0Vector,
            x1: Base.Input1Vector,
            _: Base.OutputVector,
        ) Base.OutputVector {
            return multiplyVectors(T, x0, x1);
        }
    };
}

fn AccumulateUnit(comptime T: type) type {
    const UnitBase = UnrollerUnit(T, T);
    return struct {
        pub const Base: type = UnitBase;

        pub fn func(
            _: *@This(),
            _: isize,
            x: Base.InputVector,
            y: Base.OutputVector,
        ) Base.OutputVector {
            return addVectors(T, x, y);
        }

        pub fn storeAndShortCircuit(
            _: *@This(),
            _: isize,
            _: []T,
            _: Base.OutputVector,
        ) bool {
            return true;
        }

        pub fn maskStore(
            _: *@This(),
            _: isize,
            _: []T,
            _: Base.OutputVector,
            _: isize,
        ) usize {
            return 0;
        }

        pub fn reduceFinal(
            _: *@This(),
            value: Base.OutputVector,
            output: []T,
        ) usize {
            std.debug.assert(output.len >= 1);
            output[0] = sumVector(T, value);
            return 1;
        }

        pub fn reduceUnrolled(
            _: *@This(),
            x0: Base.OutputVector,
            x1: Base.OutputVector,
            x2: Base.OutputVector,
            value: Base.OutputVector,
        ) Base.OutputVector {
            return addVectors(T, addVectors(T, x0, x1), addVectors(T, x2, value));
        }
    };
}

fn DotUnit(comptime T: type) type {
    const UnitBase = UnrollerUnit2D(T, T, T);
    return struct {
        pub const Base: type = UnitBase;

        pub fn func(
            _: *@This(),
            _: isize,
            x0: Base.Input0Vector,
            x1: Base.Input1Vector,
            y: Base.OutputVector,
        ) Base.OutputVector {
            return addVectors(T, multiplyVectors(T, x0, x1), y);
        }

        pub fn storeAndShortCircuit(
            _: *@This(),
            _: isize,
            _: []T,
            _: Base.OutputVector,
        ) bool {
            return true;
        }

        pub fn maskStore(
            _: *@This(),
            _: isize,
            _: []T,
            _: Base.OutputVector,
            _: isize,
        ) usize {
            return 0;
        }

        pub fn reduceFinal(
            _: *@This(),
            value: Base.OutputVector,
            output: []T,
        ) usize {
            std.debug.assert(output.len >= 1);
            output[0] = sumVector(T, value);
            return 1;
        }

        pub fn reduceUnrolled(
            _: *@This(),
            x0: Base.OutputVector,
            x1: Base.OutputVector,
            x2: Base.OutputVector,
            value: Base.OutputVector,
        ) Base.OutputVector {
            return addVectors(T, addVectors(T, x0, x1), addVectors(T, x2, value));
        }
    };
}

fn MinUnit(comptime T: type) type {
    const UnitBase = UnrollerUnit(T, T);
    return struct {
        pub const Base: type = UnitBase;

        pub fn func(
            _: *@This(),
            _: isize,
            x: Base.InputVector,
            y: Base.OutputVector,
        ) Base.OutputVector {
            return @min(x, y);
        }

        pub fn yInit(_: *@This()) Base.OutputVector {
            return @splat(highestValue(T));
        }

        pub fn maskLoad(
            _: *@This(),
            index: isize,
            input: []const T,
            places: isize,
        ) Base.InputVector {
            return Base.maskLoadOr(@splat(highestValue(T)), index, input, places);
        }

        pub fn storeAndShortCircuit(
            _: *@This(),
            _: isize,
            _: []T,
            _: Base.OutputVector,
        ) bool {
            return true;
        }

        pub fn maskStore(
            _: *@This(),
            _: isize,
            _: []T,
            _: Base.OutputVector,
            _: isize,
        ) usize {
            return 0;
        }

        pub fn reduceFinal(
            _: *@This(),
            value: Base.OutputVector,
            output: []T,
        ) usize {
            std.debug.assert(output.len >= 1);
            output[0] = minVector(T, value);
            return 1;
        }

        pub fn reduceUnrolled(
            _: *@This(),
            x0: Base.OutputVector,
            x1: Base.OutputVector,
            x2: Base.OutputVector,
            value: Base.OutputVector,
        ) Base.OutputVector {
            return @min(@min(x0, x1), @min(x2, value));
        }
    };
}

fn ConvertUnit(comptime From: type, comptime To: type) type {
    const UnitBase = UnrollerUnit(From, To);
    return struct {
        pub const Base: type = UnitBase;

        pub fn func(
            _: *@This(),
            _: isize,
            x: Base.InputVector,
            _: Base.OutputVector,
        ) Base.OutputVector {
            var result: Base.OutputVector = undefined;
            inline for (0..Base.actual_lanes) |lane_index| {
                result[lane_index] = convertScalar(To, x[lane_index]);
            }
            return result;
        }
    };
}

fn FindUnit(comptime T: type) type {
    const Index = signedLane(@sizeOf(T));
    const UnitBase = UnrollerUnit(T, Index);
    return struct {
        needle: T,

        pub const Base: type = UnitBase;

        pub fn func(
            self: *@This(),
            index: isize,
            x: Base.InputVector,
            y: Base.OutputVector,
        ) Base.OutputVector {
            inline for (0..Base.actual_lanes) |lane_index| {
                if (x[lane_index] == self.needle) {
                    const found = index + @as(isize, @intCast(lane_index));
                    return @splat(@as(Index, @intCast(found)));
                }
            }
            return y;
        }

        pub fn x0Init(self: *@This()) Base.InputVector {
            return @splat(otherValue(T, self.needle));
        }

        pub fn yInit(_: *@This()) Base.OutputVector {
            return @splat(-1);
        }

        pub fn maskLoad(
            self: *@This(),
            index: isize,
            input: []const T,
            places: isize,
        ) Base.InputVector {
            return Base.maskLoadOr(@splat(otherValue(T, self.needle)), index, input, places);
        }

        pub fn storeAndShortCircuit(
            _: *@This(),
            _: isize,
            output: []Index,
            value: Base.OutputVector,
        ) bool {
            std.debug.assert(output.len >= 1);
            output[0] = value[0];
            return value[0] == -1;
        }

        pub fn maskStore(
            _: *@This(),
            _: isize,
            output: []Index,
            value: Base.OutputVector,
            _: isize,
        ) usize {
            std.debug.assert(output.len >= 1);
            output[0] = value[0];
            return 1;
        }
    };
}

const TraceUnit = struct {
    x0_inits: usize = 0,
    y_inits: usize = 0,
    loads: usize = 0,
    mask_loads: usize = 0,
    funcs: usize = 0,
    stores: usize = 0,
    mask_stores: usize = 0,
    unrolled_reductions: usize = 0,
    final_reductions: usize = 0,
    last_places: isize = 0,

    pub const Base: type = UnrollerUnit(i32, i32);

    pub fn x0Init(self: *@This()) Base.InputVector {
        self.x0_inits += 1;
        return Base.x0Init();
    }

    pub fn yInit(self: *@This()) Base.OutputVector {
        self.y_inits += 1;
        return Base.yInit();
    }

    pub fn load(self: *@This(), index: isize, input: []const i32) Base.InputVector {
        self.loads += 1;
        return Base.load(index, input);
    }

    pub fn maskLoad(
        self: *@This(),
        index: isize,
        input: []const i32,
        places: isize,
    ) Base.InputVector {
        self.mask_loads += 1;
        self.last_places = places;
        return Base.maskLoad(index, input, places);
    }

    pub fn func(
        self: *@This(),
        _: isize,
        x: Base.InputVector,
        _: Base.OutputVector,
    ) Base.OutputVector {
        self.funcs += 1;
        return x;
    }

    pub fn storeAndShortCircuit(
        self: *@This(),
        index: isize,
        output: []i32,
        value: Base.OutputVector,
    ) bool {
        self.stores += 1;
        return Base.storeAndShortCircuit(index, output, value);
    }

    pub fn maskStore(
        self: *@This(),
        index: isize,
        output: []i32,
        value: Base.OutputVector,
        places: isize,
    ) usize {
        self.mask_stores += 1;
        self.last_places = places;
        return Base.maskStore(index, output, value, places);
    }

    pub fn reduceUnrolled(
        self: *@This(),
        x0: Base.OutputVector,
        x1: Base.OutputVector,
        x2: Base.OutputVector,
        value: Base.OutputVector,
    ) Base.OutputVector {
        self.unrolled_reductions += 1;
        return Base.reduceUnrolled(x0, x1, x2, value);
    }

    pub fn reduceFinal(
        self: *@This(),
        value: Base.OutputVector,
        output: []i32,
    ) usize {
        self.final_reductions += 1;
        return Base.reduceFinal(value, output);
    }
};

const StopUnit = struct {
    funcs: usize = 0,
    stores: usize = 0,
    final_reductions: usize = 0,

    pub const Base: type = UnrollerUnit(i32, i32);

    pub fn func(
        self: *@This(),
        _: isize,
        x: Base.InputVector,
        _: Base.OutputVector,
    ) Base.OutputVector {
        self.funcs += 1;
        return x;
    }

    pub fn storeAndShortCircuit(
        self: *@This(),
        _: isize,
        _: []i32,
        _: Base.OutputVector,
    ) bool {
        self.stores += 1;
        return false;
    }

    pub fn reduceFinal(
        self: *@This(),
        _: Base.OutputVector,
        _: []i32,
    ) usize {
        self.final_reductions += 1;
        return 0;
    }
};

fn counts(lane_count: usize) [14]usize {
    return .{
        1,
        3,
        7,
        16,
        @max(lane_count / 2, 1),
        @max(2 * lane_count / 3, 1),
        lane_count,
        lane_count + 1,
        4 * lane_count / 3,
        3 * lane_count,
        8 * lane_count,
        8 * lane_count + 2,
        256 * lane_count - 1,
        256 * lane_count,
    };
}

fn verifyDotAndMin(comptime T: type) !void {
    const Base = DotUnit(T).Base;
    const max_values = 256 * Base.actual_lanes;
    var a: [max_values]T = undefined;
    var b: [max_values]T = undefined;
    var products: [max_values]T = undefined;
    for (counts(Base.actual_lanes)) |count| {
        var expected_dot_f64: f64 = 0;
        var expected_min = std.math.floatMax(T);
        for (a[0..count], b[0..count], 0..) |*a_value, *b_value, index| {
            const a_integer = @as(i32, @intCast(index * 37 % 1_024)) - 512;
            const b_integer = @as(i32, @intCast(index * 53 % 1_024)) - 512;
            a_value.* = @as(T, @floatFromInt(a_integer)) * @as(T, 1.0 / 64.0);
            b_value.* = @as(T, @floatFromInt(b_integer)) * @as(T, 1.0 / 64.0);
            expected_dot_f64 += @as(f64, @floatCast(a_value.*)) *
                @as(f64, @floatCast(b_value.*));
            expected_min = @min(expected_min, a_value.*);
        }
        const expected_dot: T = @floatCast(expected_dot_f64);
        expected_dot_f64 = @floatCast(expected_dot);

        var multiply = MultiplyUnit(T){};
        unroll2(&multiply, a[0..count], b[0..count], products[0..count]);
        var accumulate = AccumulateUnit(T){};
        var via_multiply: [1]T = undefined;
        unroll(&accumulate, products[0..count], &via_multiply);

        var dot = DotUnit(T){};
        var direct: [1]T = undefined;
        unroll2(&dot, a[0..count], b[0..count], &direct);

        const tolerance = 120.0 * @as(f64, @floatCast(std.math.floatEps(T))) *
            @abs(expected_dot_f64);
        const multiply_error = @abs(
            expected_dot_f64 - @as(f64, @floatCast(via_multiply[0])),
        );
        const direct_error = @abs(expected_dot_f64 - @as(f64, @floatCast(direct[0])));
        try std.testing.expect(multiply_error <= tolerance);
        try std.testing.expect(direct_error <= tolerance);

        var minimum = MinUnit(T){};
        var actual_min: [1]T = undefined;
        unroll(&minimum, a[0..count], &actual_min);
        try std.testing.expectEqual(expected_min, actual_min[0]);
    }
}

fn verifyConvert(comptime T: type) !void {
    const Base = ConvertUnit(T, i32).Base;
    const max_values = 256 * Base.actual_lanes;
    var input: [max_values]T = undefined;
    var integers: [max_values]i32 = undefined;
    var round_trip: [max_values]T = undefined;
    for (counts(Base.actual_lanes)) |count| {
        for (input[0..count], 0..) |*value, index| {
            value.* = @as(T, @floatFromInt(index)) * @as(T, 0.25);
        }
        var to_integer = ConvertUnit(T, i32){};
        unroll(&to_integer, input[0..count], integers[0..count]);
        for (input[0..count], integers[0..count]) |value, integer| {
            try std.testing.expectEqual(@as(i32, @intFromFloat(value)), integer);
        }
        var to_float = ConvertUnit(i32, T){};
        unroll(&to_float, integers[0..count], round_trip[0..count]);
        for (integers[0..count], round_trip[0..count]) |integer, value| {
            try std.testing.expectEqual(@as(T, @floatFromInt(integer)), value);
        }
    }
}

fn verifyFind(comptime T: type) !void {
    const Unit = FindUnit(T);
    const Index = Unit.Base.Output;
    const max_values = 256 * Unit.Base.actual_lanes;
    var input: [max_values]T = undefined;
    for (counts(Unit.Base.actual_lanes)) |count| {
        for (input[0..count], 0..) |*value, index| value.* = @floatFromInt(index);
        var found: [1]Index = undefined;

        var last = Unit{ .needle = @floatFromInt(count - 1) };
        unroll(&last, input[0..count], &found);
        try std.testing.expect(found[0] >= 0);
        try std.testing.expectEqual(last.needle, input[@intCast(found[0])]);

        var zero = Unit{ .needle = 0 };
        unroll(&zero, input[0..count], &found);
        try std.testing.expectEqual(@as(Index, 0), found[0]);

        var absent = Unit{ .needle = std.math.floatMax(T) };
        unroll(&absent, input[0..count], &found);
        try std.testing.expectEqual(@as(Index, -1), found[0]);
    }
}

fn addVectors(comptime T: type, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (comptime @typeInfo(T) == .int) a +% b else a + b;
}

fn multiplyVectors(comptime T: type, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (comptime @typeInfo(T) == .int) a *% b else a * b;
}

fn sumVector(comptime T: type, value: anytype) T {
    var result: T = 0;
    inline for (0..@typeInfo(@TypeOf(value)).vector.len) |index| {
        result = if (comptime @typeInfo(T) == .int)
            result +% value[index]
        else
            result + value[index];
    }
    return result;
}

fn minVector(comptime T: type, value: anytype) T {
    var result = value[0];
    inline for (1..@typeInfo(@TypeOf(value)).vector.len) |index| {
        result = @min(result, value[index]);
    }
    return result;
}

fn highestValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .int => std.math.maxInt(T),
        .float => std.math.floatMax(T),
        else => unreachable,
    };
}

fn otherValue(comptime T: type, value: T) T {
    return switch (@typeInfo(T)) {
        .int => value +% 1,
        .float => std.math.nan(T),
        else => unreachable,
    };
}

fn convertScalar(comptime To: type, value: anytype) To {
    return switch (@typeInfo(@TypeOf(value))) {
        .int => switch (@typeInfo(To)) {
            .int => @intCast(value),
            .float => @floatFromInt(value),
            else => unreachable,
        },
        .float => switch (@typeInfo(To)) {
            .int => @intFromFloat(value),
            .float => @floatCast(value),
            else => unreachable,
        },
        else => unreachable,
    };
}
