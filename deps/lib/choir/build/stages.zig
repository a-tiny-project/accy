//! The SPIR-V validation gate for the stage and compute emitters. It emits
//! every stage module and every shared compute kernel, runs the spirv-val its
//! first argument names over each under the oldest Vulkan environment the
//! module's version admits, and fails on any finding. It also times each stage
//! emitter against one walk over the same module, the floor any emitter pays,
//! and prints both.

const std = @import("std");
const pretty = @import("pretty");
const sys = @import("sys");
const stages = @import("choir_tests").gpu_fixture.stages;

/// Emissions per timing. The best of them is reported, since emission does
/// the same work every time and only interference makes a run slower.
const repetitions = 256;

/// Modules outside the emitter tests' cases that are validated and written all the same.
const standalone = [_]stages.Case{ stages.alloca_case, stages.contraction_case, stages.gradient_case, stages.calls_case };

const Timing = struct {
    emit_ns: u64,
    floor_ns: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        pretty.diagnostic.writeStderrText("usage: choir-spirv-val SPIRV_VAL OUT_DIR\n", .{});
        return error.InvalidArguments;
    }
    const out_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[2], .{});
    defer out_dir.close(init.io);

    var failures: u32 = 0;
    for (stages.cases) |case| {
        var lowered: stages.Session = undefined;
        try lowered.init(allocator, .standard, case.source, true);
        defer lowered.deinit(allocator);
        var parsed: stages.Session = undefined;
        try parsed.init(allocator, .standard, case.source, false);
        defer parsed.deinit(allocator);

        const words = try stages.emitSpirv(allocator, lowered.module);
        defer allocator.free(words);
        const valid = try validate(allocator, init.io, out_dir, args[1], args[2], case.name, words);
        failures += @intFromBool(!valid);

        const ops = try stages.walk(lowered.module);
        const spirv = try timeSpirv(allocator, init.io, lowered.module);
        const msl = try timeMsl(allocator, init.io, parsed.module, case);
        pretty.diagnostic.writeStdoutText(
            "{s}: ops={d} words={d} spirv_ns={d} spirv_floor_ns={d} msl_ns={d} msl_floor_ns={d}\n",
            .{
                case.name,     ops,            words.len,
                spirv.emit_ns, spirv.floor_ns, msl.emit_ns,
                msl.floor_ns,
            },
        );
    }
    for (standalone) |case| {
        const valid = try validateSource(init, out_dir, args, case.name, case.source);
        failures += @intFromBool(!valid);
    }
    for (stages.kernels) |kernel| {
        const valid = try validateSource(init, out_dir, args, kernel.name, kernel.source);
        failures += @intFromBool(!valid);
    }
    const dialect_valid = try validateDialectModule(allocator, init.io, out_dir, args[1], args[2]);
    failures += @intFromBool(!dialect_valid);
    if (failures > 0) {
        pretty.diagnostic.writeStderrText("spirv-val rejected {d} modules\n", .{failures});
        return error.SpirvValidationFailed;
    }
    const accepted = stages.cases.len + standalone.len + 1 + stages.kernels.len;
    pretty.diagnostic.writeStdoutText("spirv-val accepted {d} modules\n", .{accepted});
}

/// Lowers and emits `source`, then validates the words. `args` holds the
/// validator and the output directory after the program name.
fn validateSource(
    init: std.process.Init,
    out_dir: std.Io.Dir,
    args: []const [:0]const u8,
    name: []const u8,
    source: []const u8,
) !bool {
    const allocator = init.gpa;
    var session: stages.Session = undefined;
    try session.init(allocator, .standard, source, true);
    defer session.deinit(allocator);
    const words = try stages.emitSpirv(allocator, session.module);
    defer allocator.free(words);
    return validate(allocator, init.io, out_dir, args[1], args[2], name, words);
}

fn validateDialectModule(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: std.Io.Dir,
    spirv_val: []const u8,
    out_path: []const u8,
) !bool {
    var ctx = try stages.Context.init(allocator, .standard);
    defer ctx.deinit(allocator);
    const module = try stages.buildDialectModule(&ctx);
    defer module.erase();
    const words = try stages.emitSpirv(allocator, module);
    defer allocator.free(words);
    return validate(allocator, io, out_dir, spirv_val, out_path, "dialect", words);
}

fn validate(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: std.Io.Dir,
    spirv_val: []const u8,
    out_path: []const u8,
    name: []const u8,
    words: []const u32,
) !bool {
    var name_buffer: [64]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&name_buffer, "{s}.spv", .{name});
    try out_dir.writeFile(io, .{ .sub_path = file_name, .data = std.mem.sliceAsBytes(words) });
    const path = try std.fs.path.join(allocator, &.{ out_path, file_name });
    defer allocator.free(path);
    const environment = try stages.spirvValEnvironment(words[1]);
    const result = try sys.process.run(allocator, io, .{
        .argv = &.{ spirv_val, "--target-env", environment, path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const status = sys.process.exitCode(result.term);
    if (status == 0) return true;
    pretty.diagnostic.writeStderrText("{s}: spirv-val under {s} exited {d}\n{s}{s}", .{
        name,
        environment,
        status,
        result.stdout,
        result.stderr,
    });
    return false;
}

fn timeSpirv(allocator: std.mem.Allocator, io: std.Io, module: anytype) !Timing {
    var timing: Timing = .{ .emit_ns = std.math.maxInt(u64), .floor_ns = std.math.maxInt(u64) };
    for (0..repetitions) |_| {
        const start = std.Io.Timestamp.now(io, .awake);
        const words = try stages.emitSpirv(allocator, module);
        timing.emit_ns = @min(timing.emit_ns, elapsed(io, start));
        allocator.free(words);
        timing.floor_ns = @min(timing.floor_ns, try timeWalk(io, module));
    }
    return timing;
}

fn timeMsl(allocator: std.mem.Allocator, io: std.Io, module: anytype, case: stages.Case) !Timing {
    var timing: Timing = .{ .emit_ns = std.math.maxInt(u64), .floor_ns = std.math.maxInt(u64) };
    for (0..repetitions) |_| {
        const start = std.Io.Timestamp.now(io, .awake);
        const text = try stages.emitMsl(allocator, module, case);
        timing.emit_ns = @min(timing.emit_ns, elapsed(io, start));
        allocator.free(text);
        timing.floor_ns = @min(timing.floor_ns, try timeWalk(io, module));
    }
    return timing;
}

fn timeWalk(io: std.Io, module: anytype) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);
    std.mem.doNotOptimizeAway(try stages.walk(module));
    return elapsed(io, start);
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
}
