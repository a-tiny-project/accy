const std = @import("std");

pub const PassOptionError = error{
    DuplicatePassOption,
    InvalidPassOptionValue,
    MissingPassOptionValue,
    UnknownPassOption,
};

pub const PassOptionKind = enum {
    boolean,
    unsigned,
    string,
    choice,
};

pub const PassOptionChoice = struct {
    name: []const u8,
    description: []const u8 = "",
};

pub const PassOptionSpec = struct {
    name: []const u8,
    description: []const u8,
    kind: PassOptionKind,
    choices: []const PassOptionChoice = &.{},
    default_value: ?[]const u8 = null,

    pub fn validate(self: PassOptionSpec, value: []const u8) PassOptionError!void {
        switch (self.kind) {
            .boolean => _ = parseBoolValue(value) catch return error.InvalidPassOptionValue,
            .unsigned => {
                if (value.len == 0) return error.MissingPassOptionValue;
                _ = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidPassOptionValue;
            },
            .string => {
                if (value.len == 0) return error.MissingPassOptionValue;
            },
            .choice => {
                if (value.len == 0) return error.MissingPassOptionValue;
                for (self.choices) |choice| {
                    if (std.mem.eql(u8, choice.name, value)) return;
                }
                return error.InvalidPassOptionValue;
            },
        }
    }
};

pub const PassOptionAssignment = struct {
    name: []const u8,
    value: []const u8,
};

pub const PassOptionSet = struct {
    assignments: []const PassOptionAssignment = &.{},

    pub fn get(self: PassOptionSet, name: []const u8) ?[]const u8 {
        for (self.assignments) |assignment| {
            if (std.mem.eql(u8, assignment.name, name)) return assignment.value;
        }
        return null;
    }

    pub fn boolValue(self: PassOptionSet, name: []const u8, default: bool) PassOptionError!bool {
        const value = self.get(name) orelse return default;
        return parseBoolValue(value) catch return error.InvalidPassOptionValue;
    }

    pub fn unsignedValue(
        self: PassOptionSet,
        comptime T: type,
        name: []const u8,
        default: T,
    ) PassOptionError!T {
        const value = self.get(name) orelse return default;
        return std.fmt.parseUnsigned(T, value, 10) catch return error.InvalidPassOptionValue;
    }

    pub fn choiceValue(self: PassOptionSet, name: []const u8, default: []const u8) []const u8 {
        return self.get(name) orelse default;
    }
};

pub fn validatePassOptions(
    specs: []const PassOptionSpec,
    set: PassOptionSet,
) PassOptionError!void {
    for (set.assignments, 0..) |assignment, index| {
        const spec = lookupSpec(specs, assignment.name) orelse return error.UnknownPassOption;
        for (set.assignments[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, assignment.name)) return error.DuplicatePassOption;
        }
        try spec.validate(assignment.value);
    }
}

fn lookupSpec(specs: []const PassOptionSpec, name: []const u8) ?PassOptionSpec {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

fn parseBoolValue(value: []const u8) !bool {
    if (value.len == 0) return true;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "0")) return false;
    return error.InvalidBoolean;
}
