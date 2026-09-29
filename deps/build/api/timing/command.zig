const std = @import("std");

pub const filter_flag = "--test-filter";
pub const exclude_flag = "--test-exclude";
pub const priority_flag = "--test-priority";
pub const selection_receipt_flag = "--test-selection-receipt";
pub const supervised_receipts_flag = "--test-supervised-receipts";
pub const tree_flag = "--test-tree";
pub const cwd_flag = "--test-cwd";
pub const input_flag = "--test-input";
pub const weights_flag = "--test-weights";
pub const rows_flag = "--test-rows";
pub const seed_flag = "--seed";
pub const timeout_flag = "--test-timeout-ms";
pub const timeout_text_bytes = 20;
pub const timeout_max_ms = std.math.maxInt(u64) / std.time.ns_per_ms;

const max_arguments = 256;
const value_flags = [_][]const u8{
    filter_flag,
    exclude_flag,
    priority_flag,
    selection_receipt_flag,
    supervised_receipts_flag,
    tree_flag,
    cwd_flag,
    input_flag,
    weights_flag,
    rows_flag,
    timeout_flag,
};

pub const Failure = union(enum) {
    missing_executable,
    missing_value: []const u8,
    unsupported: []const u8,
    too_many_arguments,
};

pub const Action = union(enum) {
    run,
    help,
    failure: Failure,
};

pub fn parse(iterator: anytype) Action {
    if (iterator.next() == null) return .{ .failure = .missing_executable };
    for (0..max_arguments) |_| {
        const argument = iterator.next() orelse return .run;
        if (isHelp(argument)) return .help;
        for (value_flags) |flag| {
            if (std.mem.eql(u8, argument, flag)) {
                if (iterator.next() == null) {
                    return .{ .failure = .{ .missing_value = flag } };
                }
                break;
            }
            if (joinedValue(argument, flag)) break;
        } else {
            if (joinedValue(argument, seed_flag)) continue;
            return .{ .failure = .{ .unsupported = argument } };
        }
    }
    if (iterator.next() == null) return .run;
    return .{ .failure = .too_many_arguments };
}

fn isHelp(argument: []const u8) bool {
    return std.mem.eql(u8, argument, "-h") or
        std.mem.eql(u8, argument, "--help");
}

fn joinedValue(argument: []const u8, flag: []const u8) bool {
    return argument.len > flag.len and
        argument[flag.len] == '=' and
        std.mem.eql(u8, argument[0..flag.len], flag);
}

const SliceIterator = struct {
    values: []const []const u8,
    index: usize = 0,

    fn next(self: *SliceIterator) ?[]const u8 {
        if (self.index >= self.values.len) return null;
        defer self.index += 1;
        return self.values[self.index];
    }
};

fn parseSlice(values: []const []const u8) Action {
    var iterator = SliceIterator{ .values = values };
    return parse(&iterator);
}

test "help is terminal before test execution" {
    try std.testing.expectEqual(.help, parseSlice(&.{ "test", "--help" }));
    try std.testing.expectEqual(.help, parseSlice(&.{ "test", "-h" }));
}

test "runner and Zig value arguments remain supported" {
    const action = parseSlice(&.{
        "test",
        "--test-filter",
        "unit",
        "--test-filter=integration",
        "--test-exclude",
        "slow",
        "--test-exclude=network",
        "--test-priority",
        "startup",
        "--test-priority=shutdown",
        "--test-selection-receipt",
        "receipt.txt",
        "--test-selection-receipt=other.txt",
        "--test-supervised-receipts",
        "receipts",
        "--test-supervised-receipts=other-receipts",
        "--test-tree",
        "tree",
        "--test-cwd=lib/chic",
        "--test-input=a/b.txt=c.txt",
        "--seed=0x5eed5eed",
    });
    try std.testing.expectEqual(.run, action);
}

test "unsupported arguments fail closed" {
    const unsupported = "--listen=-";
    const action = parseSlice(&.{ "test", "--test-filter=unit", unsupported });
    try std.testing.expect(action == .failure);
    try std.testing.expectEqualStrings(unsupported, action.failure.unsupported);
}

test "value arguments fail closed when their value is missing" {
    for (value_flags) |flag| {
        const action = parseSlice(&.{ "test", flag });
        try std.testing.expect(action == .failure);
        try std.testing.expectEqualStrings(flag, action.failure.missing_value);
    }
}

test "argument count bound fails closed" {
    var values: [max_arguments + 2][]const u8 = @splat("--seed=0");
    values[0] = "test";
    const action = parseSlice(&values);
    try std.testing.expect(action == .failure);
    try std.testing.expect(action.failure == .too_many_arguments);
}

/// One decimal duration, bounded before conversion to awake nanoseconds.
pub fn timeoutValue(value: []const u8) !u64 {
    if (value.len == 0) return error.InvalidTestTimeout;
    if (value.len > timeout_text_bytes) return error.TestTimeoutOverflow;
    for (value) |byte| if (byte < '0' or byte > '9') return error.InvalidTestTimeout;
    const milliseconds = std.fmt.parseUnsigned(u64, value, 10) catch return error.TestTimeoutOverflow;
    if (milliseconds > timeout_max_ms) return error.TestTimeoutOverflow;
    return milliseconds;
}

pub fn timeoutMilliseconds(iterator: anytype) !u64 {
    _ = iterator.next() orelse return error.MissingExecutable;
    var selected: ?u64 = null;
    for (0..max_arguments) |_| {
        const argument = iterator.next() orelse return selected orelse 0;
        const value = if (std.mem.eql(u8, argument, timeout_flag))
            iterator.next() orelse return error.MissingTestTimeout
        else if (joinedValue(argument, timeout_flag))
            argument[timeout_flag.len + 1 ..]
        else {
            for (value_flags) |flag| {
                if (std.mem.eql(u8, argument, flag)) {
                    _ = iterator.next() orelse return error.MissingArgumentValue;
                    break;
                }
            }
            continue;
        };
        if (selected != null) return error.DuplicateTestTimeout;
        selected = try timeoutValue(value);
    }
    if (iterator.next() != null) return error.TooManyArguments;
    return selected orelse 0;
}

fn timeoutSlice(values: []const []const u8) !u64 {
    var iterator = SliceIterator{ .values = values };
    return timeoutMilliseconds(&iterator);
}

test "timing deadline arguments are strict unique and bounded" {
    try std.testing.expectEqual(@as(u64, 0), try timeoutSlice(&.{"test"}));
    try std.testing.expectEqual(@as(u64, 0), try timeoutSlice(&.{ "test", "--test-timeout-ms=0" }));
    try std.testing.expectEqual(@as(u64, 120000), try timeoutSlice(&.{ "test", "--test-timeout-ms", "120000" }));
    try std.testing.expectEqual(@as(u64, 0), try timeoutSlice(&.{ "test", "--test-filter", "--test-timeout-ms=7" }));
    try std.testing.expectError(error.DuplicateTestTimeout, timeoutSlice(&.{ "test", "--test-timeout-ms=1", "--test-timeout-ms=0" }));
    try std.testing.expectError(error.MissingTestTimeout, timeoutSlice(&.{ "test", "--test-timeout-ms" }));
    for ([_][]const u8{ "", "-1", "+1", " 1", "1_000", "1ms" }) |value|
        try std.testing.expectError(error.InvalidTestTimeout, timeoutValue(value));
    try std.testing.expectError(error.TestTimeoutOverflow, timeoutValue("18446744073710"));
    try std.testing.expectError(error.TestTimeoutOverflow, timeoutValue("18446744073709551616"));
    try std.testing.expectEqual(timeout_max_ms, try timeoutValue("18446744073709"));
}
