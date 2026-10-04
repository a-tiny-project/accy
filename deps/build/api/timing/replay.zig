const std = @import("std");
const pretty = @import("timing_runner_pretty");
const sys = @import("timing_runner_sys");

const max_reports = 64;

pub fn main(init: sys.process.Init) u8 {
    return run(init) catch |err| {
        pretty.diagnostic.writeStderrText(
            "test timing replay: {s}\n",
            .{@errorName(err)},
        );
        return 1;
    };
}

fn run(init: sys.process.Init) !u8 {
    var iterator = sys.process.Args.Iterator.init(init.minimal.args);
    _ = iterator.next() orelse return error.MissingExecutableArgument;
    var output_buffer: [8192]u8 = undefined;
    var output = sys.stdio.stderr().writer(sys.stdio.debugIo(), &output_buffer);
    defer output.interface.flush() catch {};
    var text_buffer: [8192]u8 = undefined;
    var text = pretty.TextWriter.init(
        &output.interface,
        &text_buffer,
        .{ .width = 100 },
    );
    defer text.writer.flush() catch {};
    var report_count: usize = 0;
    for (0..max_reports) |_| {
        const path = iterator.next() orelse break;
        const file = try std.Io.Dir.cwd().openFile(sys.fs.debugIo(), path, .{});
        defer file.close(sys.fs.debugIo());
        const size = (try file.stat(sys.fs.debugIo())).size;
        var offset: u64 = 0;
        var input_buffer: [8192]u8 = undefined;
        while (offset < size) {
            const count = try file.readPositionalAll(
                sys.fs.debugIo(),
                &input_buffer,
                offset,
            );
            if (count == 0) return error.IncompleteTimingReport;
            try text.writer.writeAll(input_buffer[0..count]);
            offset += count;
        }
        report_count += 1;
    }
    if (report_count == 0) return error.MissingTimingReports;
    if (iterator.next() != null) return error.TooManyTimingReports;
    try text.writer.flush();
    return 0;
}
