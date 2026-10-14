//! The variables a caller may carry into a governed run. Each changes how the
//! timing runner behaves and none changes what a build compiles. The list is
//! closed: the governor refuses any other name by that name, and never carries
//! the caller's environment, so PATH, HOME and the like stay on their machine.

const std = @import("std");

pub const Variable = struct {
    name: []const u8,
    values: []const []const u8,
};

/// Where the runner puts a run's test tree: `disk` or `memory`.
pub const tree = "TINY_TIMING_RUNNER_TREE";

pub const declared = [_]Variable{
    .{ .name = tree, .values = &.{ "disk", "memory" } },
};

/// One run carries each declared name at most once.
pub const count_max: usize = declared.len;
pub const name_bytes_max: usize = 64;
pub const value_bytes_max: usize = 64;

comptime {
    for (declared, 0..) |variable, index| {
        std.debug.assert(variable.name.len <= name_bytes_max);
        for (variable.values) |value| std.debug.assert(value.len <= value_bytes_max);
        for (declared[0..index]) |earlier| {
            std.debug.assert(!std.mem.eql(u8, earlier.name, variable.name));
        }
    }
}

pub const Assignment = struct {
    name: []const u8,
    value: []const u8,
};

pub const Error = error{
    /// The text has no `=` or an empty name.
    VariableMalformed,
    /// The name is not on the declared list.
    VariableUndeclared,
    /// The name is declared and the value is not one of its values.
    VariableValueUndeclared,
    /// The run already carries this name.
    VariableRepeated,
    /// The run carries more variables than `count_max`.
    VariableCountExceeded,
};

/// Reads one `NAME=VALUE` and checks it against the declared list.
pub fn parse(text: []const u8) Error!Assignment {
    const split = std.mem.indexOfScalar(u8, text, '=') orelse return error.VariableMalformed;
    if (split == 0) return error.VariableMalformed;
    const assignment = Assignment{ .name = text[0..split], .value = text[split + 1 ..] };
    try check(assignment);
    return assignment;
}

pub fn check(assignment: Assignment) Error!void {
    const variable = find(assignment.name) orelse return error.VariableUndeclared;
    for (variable.values) |value| {
        if (std.mem.eql(u8, value, assignment.value)) return;
    }
    return error.VariableValueUndeclared;
}

/// Checks a whole run's set: each assignment declared, no name twice, and no
/// more than `count_max`.
pub fn checkAll(assignments: []const Assignment) Error!void {
    if (assignments.len > count_max) return error.VariableCountExceeded;
    for (assignments, 0..) |assignment, index| {
        try check(assignment);
        for (assignments[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, assignment.name)) return error.VariableRepeated;
        }
    }
}

pub fn find(name: []const u8) ?Variable {
    for (declared) |variable| {
        if (std.mem.eql(u8, variable.name, name)) return variable;
    }
    return null;
}
