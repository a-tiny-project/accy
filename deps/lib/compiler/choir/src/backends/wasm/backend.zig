const std = @import("std");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const backends = @import("../root.zig");
const wasm = @import("root.zig");

const Allocator = std.mem.Allocator;
const BackendError = backends.interface.BackendError;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;

pub const Backend = struct {
    allocator: Allocator,
    ctx: *ir.Context,

    pub fn init(allocator: Allocator, ctx: *ir.Context) Allocator.Error!Backend {
        return .{
            .allocator = allocator,
            .ctx = ctx,
        };
    }

    pub fn deinit(_: *Backend) void {}

    pub fn verify(_: *Backend, module: *ir.Operation) BackendError!void {
        return backends.contract.verifyModule("backend/wasm/verify", module);
    }

    pub fn lower(self: *Backend, module: *ir.Operation) BackendError!*ir.Operation {
        try self.verify(module);
        return module;
    }

    pub fn emit(
        self: *Backend,
        module: *ir.Operation,
        options: backends.interface.EmitOptions,
        writer: *std.Io.Writer,
    ) BackendError!void {
        const limits = wasm.ModuleEmitter.Limits.inspect(module, options) catch |err| {
            return mapEmissionError(err);
        };
        var emitter = wasm.ModuleEmitter.init(self.allocator, limits) catch |err| {
            return mapEmissionError(err);
        };
        defer emitter.deinit(self.allocator);
        emitter.activate() catch |err| return mapEmissionError(err);
        const encoded = emitter.emit() catch |err| return mapEmissionError(err);
        writer.writeAll(encoded) catch return BackendError.CodeGenFailed;
    }

    pub fn compileModuleToArtifact(
        self: *Backend,
        module: *ir.Operation,
        options: backends.interface.EmitOptions,
    ) BackendError!backends.artifact.Artifact {
        const limits = wasm.ModuleEmitter.Limits.inspect(module, options) catch |err| {
            return mapEmissionError(err);
        };
        var emitter = wasm.ModuleEmitter.init(self.allocator, limits) catch |err| {
            return mapEmissionError(err);
        };
        defer emitter.deinit(self.allocator);
        emitter.activate() catch |err| return mapEmissionError(err);
        const encoded = emitter.emit() catch |err| return mapEmissionError(err);

        const name = options.entry orelse "module";
        var artifact = backends.artifact.webassemblyModuleArtifact(
            self.allocator,
            name,
            encoded,
        ) catch return error.OutOfMemory;
        errdefer artifact.deinit();

        var symbols = wasm.emission.symbols.Iterator.init(module, options) catch |err| {
            return mapEmissionError(err);
        };
        while (symbols.next() catch |err| return mapEmissionError(err)) |symbol| {
            switch (symbol.role) {
                .required => artifact.linkage.addRequired(.{
                    .name = symbol.name,
                    .kind = .function,
                    .binding = .external,
                }) catch return error.OutOfMemory,
                .provided => artifact.linkage.addProvided(.{
                    .name = symbol.name,
                    .kind = .function,
                    .binding = .external,
                }) catch return error.OutOfMemory,
            }
        }
        return artifact;
    }
};

fn mapEmissionError(err: wasm.emission.Error) BackendError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FunctionNotFound => error.FunctionNotFound,
        error.UnsupportedOperation => error.UnsupportedOperation,
        else => error.CodeGenFailed,
    };
}

pub fn initHandle(allocator: Allocator, ctx: *ir.Context) BackendError!backends.interface.BackendHandle {
    return backends.interface.initHandle(
        Backend,
        allocator,
        ctx,
        backends.interface.BackendTarget.wasm,
        "wasm",
        .{
            .artifact = .{ .webassembly_module = true },
        },
    );
}

test "wasm backend handle emits module bytes" {
    const allocator = std.testing.allocator;
    const ArithDialect = dialects.ArithDialect;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ctx, loc, "identity", &.{i32_type}, &.{i32_type});
    try block.addOperation(func.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{func.getArgument(0)});
    try func.getEntryBlock().addOperation(ret.op);

    var handle = try initHandle(allocator, &ctx);
    defer handle.deinit();

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try handle.emit(module.op, .{ .entry = "identity" }, &out.writer);

    const bytes = out.written();
    try std.testing.expect(bytes.len >= 8);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d }, bytes[0..4]);
}

test "wasm backend refuses overflow arithmetic by name" {
    const allocator = std.testing.allocator;
    const Arith = dialects.ArithDialect;
    inline for (.{ Arith.AddoOp, Arith.SuboOp, Arith.MuloOp }) |Op| {
        for ([_]bool{ false, true }) |used| {
            var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
            defer ctx.deinit(allocator);
            try dialects.registerAllDialects(&ctx);
            const integer = try Arith.getScalarType(&ctx, .i64);
            const module = try BuiltinDialect.ModuleOp.create(&ctx, .unknown);
            const function = try FuncDialect.FuncOp.create(&ctx, .unknown, "overflow", &.{ integer, integer }, &.{integer});
            try module.getBodyBlock().addOperation(function.op);
            const checked = try Op.create(&ctx, .unknown, function.getArgument(0), function.getArgument(1));
            try function.getEntryBlock().addOperation(checked.op);
            const value = if (used) checked.getResult() else function.getArgument(0);
            const ret = try FuncDialect.ReturnOp.create(&ctx, .unknown, &.{value});
            try function.getEntryBlock().addOperation(ret.op);
            var backend = try Backend.init(allocator, &ctx);
            defer backend.deinit();
            try std.testing.expectError(error.UnsupportedOperation, backend.compileModuleToArtifact(module.op, .{ .entry = "overflow" }));
        }
    }
}
