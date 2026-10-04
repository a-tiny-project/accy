//! Writes each stage module's x86_64 object to `<case>.o` in the directory its argument names, as
//! host functions over `gpu_abi.stage`. A module the CPU lowering refuses gets `<case>.refused`
//! instead, holding the name of the op it stopped at, so a render witness can say which stage op
//! the CPU path cannot run. Beside each object, `<case>.push` holds the push-constant bytes its
//! stages read, which the witness reports with the artifact.

const std = @import("std");
const pretty = @import("pretty");
const stages = @import("choir_tests").gpu_fixture.stages;
const cpu = @import("choir_tests").gpu_cpu;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        pretty.diagnostic.writeStderrText("usage: choir-stage-cpu OUT_DIR\n", .{});
        return error.InvalidArguments;
    }
    const out_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer out_dir.close(init.io);
    for (stages.cases ++ [_]stages.Case{ stages.alloca_case, stages.contraction_case, stages.calls_case, stages.gradient_case }) |case| {
        var session: stages.Session = undefined;
        try session.init(allocator, .standard, case.source, false);
        defer session.deinit(allocator);
        var refusal: cpu.StageRefusal = .{};
        var name_buffer: [64]u8 = undefined;
        const object = stages.emitCpuObject(allocator, session.module, case, &refusal) catch |err| switch (err) {
            error.UnsupportedOperation, error.UnsupportedStageMemory => {
                const file_name = try std.fmt.bufPrint(&name_buffer, "{s}.refused", .{case.name});
                try out_dir.writeFile(init.io, .{ .sub_path = file_name, .data = refusal.operation });
                continue;
            },
            else => return err,
        };
        defer allocator.free(object);
        const file_name = try std.fmt.bufPrint(&name_buffer, "{s}.o", .{case.name});
        try out_dir.writeFile(init.io, .{ .sub_path = file_name, .data = object });
        try stages.writePushExtent(init.io, out_dir, case, session.module);
    }
}
