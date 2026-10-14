const std = @import("std");
const alloc_arena = @import("alloc_arena");
const sys = @import("sys");

const ir = @import("../core/root.zig");
const dialects = @import("../dialects/root.zig");
const pass_mod = @import("pass/root.zig");
const pipeline_mod = @import("pipeline.zig");
const textual = @import("textual.zig");

const magic = "choir-pass-reproducer-v1";

pub const ReplayOptions = struct {
    worker_allocator: ?std.mem.Allocator = null,
};

pub const ReplayResult = struct {
    result: pass_mod.PassResult,
    stats: pass_mod.PassManagerStats,
    failure_kind: ?pass_mod.PassFailureKind,
    worker_count: usize,
};

pub fn formatPassFailureReproducerAlloc(
    allocator: std.mem.Allocator,
    reproducer: *const pass_mod.PassFailureReproducer,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writePassFailureReproducer(&out.writer, reproducer);
    return try out.toOwnedSlice();
}

pub fn writePassFailureReproducer(
    writer: *std.Io.Writer,
    reproducer: *const pass_mod.PassFailureReproducer,
) !void {
    try writer.writeAll(magic ++ "\n");
    try writer.print("max_threads {d}\n", .{reproducer.max_threads});
    try writer.print("worker_count {d}\n", .{reproducer.worker_count});
    try writer.print("verifier_enabled {s}\n", .{if (reproducer.verifier_enabled) "true" else "false"});
    try writer.print("failure_kind {s}\n", .{failureKindName(reproducer.failure_kind)});
    try writeOptionalBytes(writer, "pass_name", reproducer.pass_name);
    try writeOptionalBytes(writer, "target_op_name", reproducer.target_op_name);
    try writeOptionalBytes(writer, "target_symbol_name", reproducer.target_symbol_name);
    try writeOptionalBytes(writer, "verifier_error", verifierErrorName(reproducer));
    try writeRequiredBytes(writer, "pipeline", reproducer.pipeline);
    try writeRequiredBytes(writer, "ir", reproducer.ir);
}

pub fn writePassFailureReproducerFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    reproducer: *const pass_mod.PassFailureReproducer,
) !void {
    const bytes = try formatPassFailureReproducerAlloc(allocator, reproducer);
    defer allocator.free(bytes);
    try sys.fs.writeFile(path, bytes);
}

pub fn parsePassFailureReproducerAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) !pass_mod.PassFailureReproducer {
    var parser = FileParser{
        .allocator = allocator,
        .text = text,
    };
    return try parser.parse();
}

pub fn replayPassFailureReproducer(
    allocator: std.mem.Allocator,
    registry: *const pipeline_mod.PassRegistry,
    ctx: *ir.Context,
    reproducer: *const pass_mod.PassFailureReproducer,
    options: ReplayOptions,
) !ReplayResult {
    if (reproducer.failure_kind == .exhausted) return error.UnrecordedWorkBudget;

    var manager = pass_mod.PassManager.init(allocator);
    defer manager.deinit();

    try textual.parsePassPipeline(registry, reproducer.pipeline, &manager);
    if (reproducer.verifier_enabled) manager.enableVerifier();

    const op = try ir.parse.operation(ctx, reproducer.ir);
    defer op.erase();

    const result = manager.runWithOptions(op, ctx, .{
        .max_threads = reproducer.max_threads,
        .worker_allocator = options.worker_allocator orelse allocator,
    });

    const replayed = manager.getLastFailureReproducer();
    return .{
        .result = result,
        .stats = manager.stats,
        .failure_kind = if (replayed) |failure| failure.failure_kind else null,
        .worker_count = if (replayed) |failure| failure.worker_count else 1,
    };
}

fn writeOptionalBytes(writer: *std.Io.Writer, name: []const u8, value: ?[]const u8) !void {
    if (value) |bytes| {
        try writeRequiredBytes(writer, name, bytes);
    } else {
        try writer.print("{s} none\n", .{name});
    }
}

fn writeRequiredBytes(writer: *std.Io.Writer, name: []const u8, bytes: []const u8) !void {
    try writer.print("{s} bytes {d}\n", .{ name, bytes.len });
    try writer.writeAll(bytes);
    try writer.writeByte('\n');
}

fn failureKindName(kind: ?pass_mod.PassFailureKind) []const u8 {
    return switch (kind orelse return "none") {
        .exhausted => "exhausted",
        .pass => "pass",
        .verifier => "verifier",
        .target => "target",
    };
}

fn parseFailureKind(text: []const u8) !?pass_mod.PassFailureKind {
    if (std.mem.eql(u8, text, "none")) return null;
    if (std.mem.eql(u8, text, "exhausted")) return .exhausted;
    if (std.mem.eql(u8, text, "pass")) return .pass;
    if (std.mem.eql(u8, text, "verifier")) return .verifier;
    if (std.mem.eql(u8, text, "target")) return .target;
    return error.InvalidPassFailureReproducer;
}

fn verifierErrorName(reproducer: *const pass_mod.PassFailureReproducer) ?[]const u8 {
    if (reproducer.verifier_error_name) |name| return name;
    if (reproducer.verifier_error) |err| return @errorName(err);
    return null;
}

const FileParser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    index: usize = 0,

    fn parse(self: *FileParser) !pass_mod.PassFailureReproducer {
        try self.expectLine(magic);
        const max_threads = try self.readUsizeField("max_threads");
        const worker_count = try self.readUsizeField("worker_count");
        const verifier_enabled = try self.readBoolField("verifier_enabled");
        const failure_kind = try parseFailureKind(try self.readScalarField("failure_kind"));
        const pass_name = try self.readOptionalBytes("pass_name");
        errdefer if (pass_name) |value| self.allocator.free(value);
        const target_op_name = try self.readOptionalBytes("target_op_name");
        errdefer if (target_op_name) |value| self.allocator.free(value);
        const target_symbol_name = try self.readOptionalBytes("target_symbol_name");
        errdefer if (target_symbol_name) |value| self.allocator.free(value);
        const verifier_error_name = try self.readOptionalBytes("verifier_error");
        errdefer if (verifier_error_name) |value| self.allocator.free(value);
        const pipeline = try self.readRequiredBytes("pipeline");
        errdefer self.allocator.free(pipeline);
        const snapshot = try self.readRequiredBytes("ir");
        errdefer self.allocator.free(snapshot);
        if (self.index != self.text.len) return error.InvalidPassFailureReproducer;

        return .{
            .pipeline = pipeline,
            .ir = snapshot,
            .max_threads = max_threads,
            .worker_count = worker_count,
            .verifier_enabled = verifier_enabled,
            .failure_kind = failure_kind,
            .pass_name = pass_name,
            .target_op_name = target_op_name,
            .target_symbol_name = target_symbol_name,
            .verifier_error = null,
            .verifier_error_name = verifier_error_name,
        };
    }

    fn expectLine(self: *FileParser, expected: []const u8) !void {
        const line = try self.readLine();
        if (!std.mem.eql(u8, line, expected)) return error.InvalidPassFailureReproducer;
    }

    fn readUsizeField(self: *FileParser, name: []const u8) !usize {
        const value = try self.readScalarField(name);
        return std.fmt.parseUnsigned(usize, value, 10) catch error.InvalidPassFailureReproducer;
    }

    fn readBoolField(self: *FileParser, name: []const u8) !bool {
        const value = try self.readScalarField(name);
        if (std.mem.eql(u8, value, "true")) return true;
        if (std.mem.eql(u8, value, "false")) return false;
        return error.InvalidPassFailureReproducer;
    }

    fn readScalarField(self: *FileParser, name: []const u8) ![]const u8 {
        const line = try self.readLine();
        if (!std.mem.startsWith(u8, line, name)) return error.InvalidPassFailureReproducer;
        if (line.len <= name.len or line[name.len] != ' ') return error.InvalidPassFailureReproducer;
        return line[name.len + 1 ..];
    }

    fn readOptionalBytes(self: *FileParser, name: []const u8) !?[]u8 {
        const line = try self.readLine();
        if (!std.mem.startsWith(u8, line, name)) return error.InvalidPassFailureReproducer;
        if (line.len <= name.len or line[name.len] != ' ') return error.InvalidPassFailureReproducer;
        const rest = line[name.len + 1 ..];
        if (std.mem.eql(u8, rest, "none")) return null;
        return try self.readBytesAfterHeader(rest);
    }

    fn readRequiredBytes(self: *FileParser, name: []const u8) ![]u8 {
        const line = try self.readLine();
        if (!std.mem.startsWith(u8, line, name)) return error.InvalidPassFailureReproducer;
        if (line.len <= name.len or line[name.len] != ' ') return error.InvalidPassFailureReproducer;
        return try self.readBytesAfterHeader(line[name.len + 1 ..]);
    }

    fn readBytesAfterHeader(self: *FileParser, rest: []const u8) ![]u8 {
        if (!std.mem.startsWith(u8, rest, "bytes ")) return error.InvalidPassFailureReproducer;
        const len = std.fmt.parseUnsigned(usize, rest["bytes ".len..], 10) catch return error.InvalidPassFailureReproducer;
        if (self.index + len > self.text.len) return error.InvalidPassFailureReproducer;
        const bytes = self.text[self.index .. self.index + len];
        self.index += len;
        if (self.index >= self.text.len or self.text[self.index] != '\n') return error.InvalidPassFailureReproducer;
        self.index += 1;
        return try self.allocator.dupe(u8, bytes);
    }

    fn readLine(self: *FileParser) ![]const u8 {
        if (self.index >= self.text.len) return error.InvalidPassFailureReproducer;
        const start = self.index;
        while (self.index < self.text.len and self.text[self.index] != '\n') self.index += 1;
        if (self.index >= self.text.len) return error.InvalidPassFailureReproducer;
        const line = self.text[start..self.index];
        self.index += 1;
        return line;
    }
};

fn failingPass(ctx: *pass_mod.PassContext) pass_mod.PassResult {
    _ = ctx;
    return .failure;
}

fn buildReplayRegistry(allocator: std.mem.Allocator) !pipeline_mod.PassRegistry {
    var registry = pipeline_mod.PassRegistry.init(allocator);
    errdefer registry.deinit();
    try registry.registerPass(.{
        .name = "choir-reproducer-test-fail",
        .description = "test failure pass",
        .pass = .{
            .name = "choir-reproducer-test-fail",
            .description = "test failure pass",
            .run_fn = failingPass,
            .mutation_scope = .read_only,
        },
    });
    return registry;
}

fn buildReplayModule(ctx: *ir.Context) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    const body = module.getBodyBlock();
    const i32_type = try dialects.ArithDialect.getScalarType(ctx, .i32);
    for (0..2) |index| {
        const name = try std.fmt.allocPrint(ir.context.transientAllocator(ctx), "reproducer_{d}", .{index});
        var func = try dialects.FuncDialect.FuncOp.create(ctx, loc, name, &.{i32_type}, &.{i32_type});
        try body.addOperation(func.op);
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{func.getArgument(0)});
        try func.getEntryBlock().addOperation(ret.op);
    }
    return module.op;
}

fn initReplayContext(allocator: std.mem.Allocator) !ir.Context {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    errdefer ctx.deinit(allocator);
    try dialects.registerChoirDialect(&ctx);
    _ = try ctx.getOrLoadDialect("builtin");
    _ = try ctx.getOrLoadDialect("arith");
    _ = try ctx.getOrLoadDialect("func");
    return ctx;
}
