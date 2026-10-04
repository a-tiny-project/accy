//! Writes the MSL of each stage module, and of the standalone `alloca`, `contraction`, `gradient`
//! and `calls` modules, to `<case>.metal` in the directory its argument names. An MSL source holds
//! one fragment entry, so `gradient-call.metal` holds the `gradient` module's second. The Metal
//! witnesses read these files, so they compile and draw exactly the text the stage emitter produces
//! and never link the compiler. Beside each, `<case>.push` holds the push-constant bytes its stages
//! read.

const std = @import("std");
const pretty = @import("pretty");
const stages = @import("choir_tests").gpu_fixture.stages;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        pretty.diagnostic.writeStderrText("usage: choir-stage-msl OUT_DIR\n", .{});
        return error.InvalidArguments;
    }
    const out_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer out_dir.close(init.io);
    for (stages.cases ++ [_]stages.Case{ stages.alloca_case, stages.contraction_case, stages.gradient_case, stages.gradient_call_case, stages.calls_case }) |case| {
        var parsed: stages.Session = undefined;
        try parsed.init(allocator, .standard, case.source, false);
        defer parsed.deinit(allocator);
        const text = try stages.emitMsl(allocator, parsed.module, case);
        defer allocator.free(text);
        var name_buffer: [64]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&name_buffer, "{s}.metal", .{case.name});
        try out_dir.writeFile(init.io, .{ .sub_path = file_name, .data = text });
        try stages.writePushExtent(init.io, out_dir, case, parsed.module);
    }
}
