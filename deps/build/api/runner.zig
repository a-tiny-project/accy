const std = @import("std");
const builtin = @import("builtin");
const execution = @import("timing/execution.zig");
const evidence = @import("validation/emitter.zig");
const options = @import("validation_binding");
const protocol = @import("validation");
const model = if (options.model_namespace.len == 0)
    protocol
else
    @field(protocol, options.model_namespace);

pub const std_options: std.Options = .{ .log_level = .warn };

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        writer.interface.print("validation runner: {s}\n", .{@errorName(err)}) catch {};
        writer.interface.flush() catch {};
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    @disableInstrumentation();
    try evidence.prepare(init.minimal);
    const tests = builtin.test_functions;
    if (tests.len == 0) return error.NoSelectedTests;
    if (tests.len > model.max_tests) return error.TooManyTests;
    var names: [model.max_tests][]const u8 = undefined;
    for (tests, 0..) |entry, index| names[index] = entry.name;
    try evidence.selected(names[0..tests.len]);

    var rows: [model.max_tests]execution.Row = undefined;
    var failed = false;
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(init.io, &buffer);
    defer writer.interface.flush() catch {};
    for (tests, 0..) |entry, index| {
        const result = execution.run(init.gpa, init.minimal, init.io, entry, null, index, 0);
        rows[index] = .{
            .name = entry.name,
            .test_ns = result.test_ns,
            .teardown_ns = result.teardown_ns,
            .status = result.status,
            .leaked = result.leaked,
        };
        if (result.status != .ok or result.leaked) {
            failed = true;
            try writer.interface.print("[{s}] {s}", .{ @tagName(result.status), entry.name });
            if (result.error_name.len != 0) {
                try writer.interface.print(": {s}", .{result.error_name});
            }
            if (result.leak_message.len != 0) {
                try writer.interface.print(": {s}", .{result.leak_message});
            }
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
        }
    }
    try evidence.completed(rows[0..tests.len]);
    return if (failed) 1 else 0;
}
