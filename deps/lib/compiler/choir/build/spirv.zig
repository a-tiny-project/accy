//! Writes each stage module's SPIR-V to `<case>.spv` in the directory its argument names. Render
//! witnesses outside the compiler read these files, so they draw with exactly the words the stage
//! emitter produces and never link the compiler. Beside each, `<case>.push` holds the
//! push-constant bytes its stages read.

const std = @import("std");
const pretty = @import("pretty");
const stages = @import("choir_tests").gpu_fixture.stages;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        pretty.diagnostic.writeStderrText("usage: choir-stage-spirv OUT_DIR\n", .{});
        return error.InvalidArguments;
    }
    const out_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer out_dir.close(init.io);
    for (stages.cases ++ [_]stages.Case{ stages.alloca_case, stages.contraction_case, stages.gradient_case, stages.calls_case }) |case| {
        var lowered: stages.Session = undefined;
        try lowered.init(allocator, .standard, case.source, true);
        defer lowered.deinit(allocator);
        const words = try stages.emitSpirv(allocator, lowered.module);
        defer allocator.free(words);
        var name_buffer: [64]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&name_buffer, "{s}.spv", .{case.name});
        try out_dir.writeFile(init.io, .{ .sub_path = file_name, .data = std.mem.sliceAsBytes(words) });
        try stages.writePushExtent(init.io, out_dir, case, lowered.module);
    }
}
