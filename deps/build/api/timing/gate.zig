const std = @import("std");
const pretty = @import("timing_runner_pretty");
const sys = @import("timing_runner_sys");

const max_receipts = 32;
const max_receipt_bytes = 64;

pub fn main(init: sys.process.Init) u8 {
    return run(init) catch |err| {
        pretty.diagnostic.writeStderrText(
            "test selection gate: {s}\n",
            .{@errorName(err)},
        );
        return 1;
    };
}

fn run(init: sys.process.Init) !u8 {
    var iterator = sys.process.Args.Iterator.init(init.minimal.args);
    _ = iterator.next() orelse return error.MissingExecutableArgument;
    var selected: u64 = 0;
    var receipt_count: usize = 0;
    while (iterator.next()) |path| {
        if (receipt_count == max_receipts) {
            return error.TooManySelectionReceipts;
        }
        var storage: [max_receipt_bytes]u8 = undefined;
        const bytes = try std.Io.Dir.cwd().readFile(
            sys.fs.debugIo(),
            path,
            &storage,
        );
        const count = std.fmt.parseUnsigned(
            u64,
            std.mem.trim(u8, bytes, &std.ascii.whitespace),
            10,
        ) catch return error.InvalidSelectionReceipt;
        selected = std.math.add(u64, selected, count) catch
            return error.SelectionCountOverflow;
        receipt_count += 1;
    }
    if (receipt_count == 0) return error.MissingSelectionReceipts;
    if (selected == 0) {
        pretty.diagnostic.writeStderrText(
            "FAIL no tests matched the requested filters across {d} artifacts\n",
            .{receipt_count},
        );
        return 1;
    }
    pretty.diagnostic.writeStderrText(
        "PASS {d} tests matched the requested filters across {d} artifacts\n",
        .{ selected, receipt_count },
    );
    return 0;
}
