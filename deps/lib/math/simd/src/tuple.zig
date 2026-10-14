const std = @import("std");

pub fn create2(comptime D: type, v0: D.Vector, v1: D.Vector) [2]D.Vector {
    return .{ v0, v1 };
}

pub fn create3(
    comptime D: type,
    v0: D.Vector,
    v1: D.Vector,
    v2: D.Vector,
) [3]D.Vector {
    return .{ v0, v1, v2 };
}

pub fn create4(
    comptime D: type,
    v0: D.Vector,
    v1: D.Vector,
    v2: D.Vector,
    v3: D.Vector,
) [4]D.Vector {
    return .{ v0, v1, v2, v3 };
}

pub fn get2(comptime index: usize, value: anytype) @TypeOf(value[index]) {
    if (comptime index >= 2) @compileError("get2 index must be less than two");
    return value[index];
}

pub fn get3(comptime index: usize, value: anytype) @TypeOf(value[index]) {
    if (comptime index >= 3) @compileError("get3 index must be less than three");
    return value[index];
}

pub fn get4(comptime index: usize, value: anytype) @TypeOf(value[index]) {
    if (comptime index >= 4) @compileError("get4 index must be less than four");
    return value[index];
}

pub fn set2(comptime index: usize, value: anytype, replacement: @TypeOf(value[index])) @TypeOf(value) {
    if (comptime index >= 2) @compileError("set2 index must be less than two");
    var result = value;
    result[index] = replacement;
    return result;
}

pub fn set3(comptime index: usize, value: anytype, replacement: @TypeOf(value[index])) @TypeOf(value) {
    if (comptime index >= 3) @compileError("set3 index must be less than three");
    var result = value;
    result[index] = replacement;
    return result;
}

pub fn set4(comptime index: usize, value: anytype, replacement: @TypeOf(value[index])) @TypeOf(value) {
    if (comptime index >= 4) @compileError("set4 index must be less than four");
    var result = value;
    result[index] = replacement;
    return result;
}
