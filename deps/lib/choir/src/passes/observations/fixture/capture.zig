const std = @import("std");
const choir = @import("../../../root.zig");
const fixture = @import("root.zig");
const ir = choir.ir;
const instrumentation = choir.passes.instrumentation;

/// Captures deterministic observations in caller-owned storage. Callback write
/// failures propagate after the pipeline; partial observations are never accepted.
pub fn collect(allocator: std.mem.Allocator, selected: fixture.Fixture) ![]u8 {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const module = try fixture.build(&ctx, selected);
    defer module.erase();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.print("fixture {s}\nobservation input-ir\n", .{@tagName(selected)});
    try ir.dump.writeOperation(allocator, writer, module);
    try writer.writeAll("observation pass-trace-and-ir-after-each-pass\n");

    var capture = choir.diagnostics.CaptureBuffer.init(allocator);
    defer capture.deinit();
    var scope = ctx.captureDiagnostics(&capture);
    var guard = scope.enter();
    defer guard.deinit();
    var recorder = Recorder{ .allocator = allocator, .writer = writer };
    var manager = choir.passes.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addInstrumentation(recorder.observer());
    try fixture.addPasses(&manager, selected);
    const result = manager.run(module, &ctx);
    if (recorder.failure) |err| return err;
    if (manager.getLastVerifierFailure()) |failure| {
        const diagnostic = choir.diagnostics.captureVerifierFailure(
            failure.pass_name,
            module,
            ir.verify.default_options,
            failure.err,
        );
        var pending = ctx.emitDiagnostic(diagnostic.diagnostic());
        defer pending.deinit();
        _ = try pending.emit();
    }
    try writer.print("observation result\n{s}\n", .{@tagName(result)});
    try writer.print(
        "observation structured-diagnostics\ncount={d}\n",
        .{capture.diagnostics.items.len},
    );
    for (capture.diagnostics.items, 0..) |diagnostic, index| {
        try writer.print(
            "diagnostic[{d}] severity={s} location={f} operation={s} error={s}\n" ++
                "message={s}\nnotes={d}\n",
            .{
                index,
                @tagName(diagnostic.severity),
                diagnostic.location,
                diagnostic.operationName() orelse "none",
                diagnostic.error_name orelse "none",
                diagnostic.message,
                diagnostic.notes.len,
            },
        );
        for (diagnostic.notes) |note| {
            try writer.print("note location={f} message={s}\n", .{ note.location, note.message });
        }
        try writer.print("metadata={d}\n", .{diagnostic.metadata.len});
        for (diagnostic.metadata) |entry| {
            try writer.print("metadata {s}={s}\n", .{ entry.name, entry.value });
        }
    }
    return allocator.dupe(u8, output.written());
}

const Recorder = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    failure: ?anyerror = null,

    const PipelineEvent = struct {
        info: instrumentation.PipelineInfo,
        op: *ir.Operation,
        failed: bool = false,
    };
    const Event = union(enum) {
        pipeline_begin: PipelineEvent,
        pipeline_end: PipelineEvent,
        pass_begin: instrumentation.PassInfo,
        pass_end: struct { info: instrumentation.PassInfo, modified: bool },
        pass_failed: instrumentation.PassInfo,
        analysis_begin: instrumentation.AnalysisInfo,
        analysis_end: instrumentation.AnalysisInfo,
        statistic: instrumentation.PassStatisticInfo,
    };

    fn observer(self: *Recorder) instrumentation.PassInstrumentation {
        return .{
            .ctx = self,
            .runBeforePipeline = beforePipeline,
            .runAfterPipeline = afterPipeline,
            .runBeforePass = beforePass,
            .runAfterPass = afterPass,
            .runAfterPassFailed = afterPassFailed,
            .runBeforeAnalysis = beforeAnalysis,
            .runAfterAnalysis = afterAnalysis,
            .runPassStatistic = statistic,
        };
    }

    fn record(context: ?*anyopaque, event: Event) void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        if (self.failure != null) return;
        self.write(event) catch |err| {
            self.failure = err;
        };
    }

    fn write(self: *Recorder, event: Event) !void {
        const writer = self.writer;
        switch (event) {
            .pipeline_begin, .pipeline_end => |pipeline| try writer.print(
                "{s} depth={d} target={s} operation={s} failed={}\n",
                .{
                    @tagName(event),
                    pipeline.info.depth,
                    pipeline.info.target_op_name orelse "any",
                    pipeline.op.name.name,
                    pipeline.failed,
                },
            ),
            .pass_begin, .pass_failed => |pass| {
                try writer.print("{s} name={s} scope={s} target={s}\n", .{
                    @tagName(event),
                    pass.name,
                    @tagName(pass.mutation_scope),
                    pass.target_op.?.name.name,
                });
                if (event == .pass_failed) try self.dumpAfterPass(pass);
            },
            .pass_end => |pass| {
                try writer.print(
                    "pass_end name={s} modified={}\n",
                    .{ pass.info.name, pass.modified },
                );
                try self.dumpAfterPass(pass.info);
            },
            .analysis_begin, .analysis_end => |analysis| try writer.print(
                "{s} name={s} target={s}\n",
                .{ @tagName(event), analysis.name, analysis.target_op.name.name },
            ),
            .statistic => |stat| try writer.print(
                "statistic pass={s} name={s} value={d}\n",
                .{ stat.pass.name, stat.name, stat.value },
            ),
        }
    }

    fn dumpAfterPass(self: *Recorder, pass: instrumentation.PassInfo) !void {
        try self.writer.print("ir-after-pass {s}\n", .{pass.name});
        try ir.dump.writeOperation(self.allocator, self.writer, pass.target_op.?);
    }

    fn beforePipeline(
        context: ?*anyopaque,
        info: instrumentation.PipelineInfo,
        op: *ir.Operation,
    ) void {
        record(context, .{ .pipeline_begin = .{ .info = info, .op = op } });
    }

    fn afterPipeline(
        context: ?*anyopaque,
        info: instrumentation.PipelineInfo,
        op: *ir.Operation,
        failed: bool,
    ) void {
        record(context, .{ .pipeline_end = .{ .info = info, .op = op, .failed = failed } });
    }

    fn beforePass(context: ?*anyopaque, info: instrumentation.PassInfo) void {
        record(context, .{ .pass_begin = info });
    }

    fn afterPass(context: ?*anyopaque, info: instrumentation.PassInfo, modified: bool) void {
        record(context, .{ .pass_end = .{ .info = info, .modified = modified } });
    }

    fn afterPassFailed(context: ?*anyopaque, info: instrumentation.PassInfo) void {
        record(context, .{ .pass_failed = info });
    }

    fn beforeAnalysis(context: ?*anyopaque, info: instrumentation.AnalysisInfo) void {
        record(context, .{ .analysis_begin = info });
    }

    fn afterAnalysis(context: ?*anyopaque, info: instrumentation.AnalysisInfo) void {
        record(context, .{ .analysis_end = info });
    }

    fn statistic(context: ?*anyopaque, info: instrumentation.PassStatisticInfo) void {
        record(context, .{ .statistic = info });
    }
};
