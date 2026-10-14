const std = @import("std");

pub const filter_flag = "--test-filter";
pub const exclude_flag = "--test-exclude";
pub const priority_flag = "--test-priority";
pub const selection_receipt_flag = "--test-selection-receipt";
pub const supervised_receipts_flag = "--test-supervised-receipts";
pub const tree_flag = "--test-tree";
pub const cwd_flag = "--test-cwd";
/// Where the tree lives: `disk`, the directory `tree_flag` names, or `memory`.
pub const tree_store_flag = "--test-tree-store";
pub const input_flag = "--test-input";
pub const weights_flag = "--test-weights";
pub const rows_flag = "--test-rows";
pub const seed_flag = "--seed";
pub const timeout_flag = "--test-timeout-ms";
/// One test's own deadline, `<milliseconds>=<test name>`, in place of `timeout_flag`'s.
pub const deadline_flag = "--test-deadline-ms";
/// The most tests one run may give their own deadline.
pub const max_deadlines = 8;
/// No test's own deadline exceeds this, so a hang ends within it whatever the argv lists.
pub const deadline_max_ms: u64 = 600_000;
/// The largest executable, in bytes, a run admits before its first test.
pub const binary_limit_flag = "--test-binary-limit";
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
    tree_store_flag,
    input_flag,
    weights_flag,
    rows_flag,
    timeout_flag,
    deadline_flag,
    binary_limit_flag,
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

pub const Deadline = struct {
    name: []const u8,
    milliseconds: u64,
};

/// The tests an argv gives their own deadline. Names borrow from the argv.
pub const Deadlines = struct {
    entries: [max_deadlines]Deadline = undefined,
    count: usize = 0,

    pub fn slice(self: *const Deadlines) []const Deadline {
        return self.entries[0..self.count];
    }
};

/// One `<milliseconds>=<test name>` value. The name is the rest of the value, so it may
/// hold any byte a test name does.
pub fn deadlineValue(value: []const u8) !Deadline {
    const separator = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidTestDeadline;
    const name = value[separator + 1 ..];
    if (name.len == 0) return error.InvalidTestDeadline;
    const milliseconds = timeoutValue(value[0..separator]) catch return error.InvalidTestDeadline;
    if (milliseconds == 0) return error.InvalidTestDeadline;
    if (milliseconds > deadline_max_ms) return error.TestDeadlineAboveMaximum;
    return .{ .name = name, .milliseconds = milliseconds };
}

/// Every test the argv gives its own deadline. A test listed twice is refused, whatever
/// its two values, so no entry can shadow another.
pub fn deadlines(iterator: anytype) !Deadlines {
    _ = iterator.next() orelse return error.MissingExecutable;
    var selected: Deadlines = .{};
    for (0..max_arguments) |_| {
        const argument = iterator.next() orelse return selected;
        const value = if (std.mem.eql(u8, argument, deadline_flag))
            iterator.next() orelse return error.MissingTestDeadline
        else if (joinedValue(argument, deadline_flag))
            argument[deadline_flag.len + 1 ..]
        else {
            for (value_flags) |flag| {
                if (std.mem.eql(u8, argument, flag)) {
                    _ = iterator.next() orelse return error.MissingArgumentValue;
                    break;
                }
            }
            continue;
        };
        const entry = try deadlineValue(value);
        for (selected.slice()) |prior| {
            if (std.mem.eql(u8, prior.name, entry.name)) return error.DuplicateTestDeadline;
        }
        if (selected.count == max_deadlines) return error.TooManyTestDeadlines;
        selected.entries[selected.count] = entry;
        selected.count += 1;
    }
    if (iterator.next() != null) return error.TooManyArguments;
    return selected;
}

/// The position of the test named exactly `name`, or null when `test_fns` has none.
pub fn testIndex(test_fns: anytype, name: []const u8) ?usize {
    for (test_fns, 0..) |test_fn, index| {
        if (std.mem.eql(u8, test_fn.name, name)) return index;
    }
    return null;
}

/// The run's executable limit in bytes, or null when the argv sets none.
pub fn binaryLimit(iterator: anytype) !?u64 {
    _ = iterator.next() orelse return error.MissingExecutable;
    var selected: ?u64 = null;
    for (0..max_arguments) |_| {
        const argument = iterator.next() orelse return selected;
        const value = if (std.mem.eql(u8, argument, binary_limit_flag))
            iterator.next() orelse return error.MissingBinaryLimit
        else if (joinedValue(argument, binary_limit_flag))
            argument[binary_limit_flag.len + 1 ..]
        else {
            for (value_flags) |flag| {
                if (std.mem.eql(u8, argument, flag)) {
                    _ = iterator.next() orelse return error.MissingArgumentValue;
                    break;
                }
            }
            continue;
        };
        if (selected != null) return error.DuplicateBinaryLimit;
        if (value.len == 0) return error.InvalidBinaryLimit;
        for (value) |byte| if (byte < '0' or byte > '9') return error.InvalidBinaryLimit;
        const bytes = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidBinaryLimit;
        if (bytes == 0) return error.InvalidBinaryLimit;
        selected = bytes;
    }
    if (iterator.next() != null) return error.TooManyArguments;
    return selected;
}

fn binaryLimitSlice(values: []const []const u8) !?u64 {
    var iterator = SliceIterator{ .values = values };
    return binaryLimit(&iterator);
}

fn timeoutSlice(values: []const []const u8) !u64 {
    var iterator = SliceIterator{ .values = values };
    return timeoutMilliseconds(&iterator);
}

fn deadlinesSlice(values: []const []const u8) !Deadlines {
    var iterator = SliceIterator{ .values = values };
    return deadlines(&iterator);
}
