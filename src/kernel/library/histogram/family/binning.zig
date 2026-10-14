const std = @import("std");

pub const Policy = enum(u64) {
    lower_inclusive_upper_exclusive = 0,
};

pub const policy_parameter_name = "histogram_binning_policy";

pub fn code(policy: Policy) u64 {
    return @backingInt(policy);
}

pub fn fromCode(value: u64) ?Policy {
    return std.enums.fromInt(Policy, value);
}
