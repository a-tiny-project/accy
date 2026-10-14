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
    math_imports: bool = false,

    pub fn init(allocator: Allocator, ctx: *ir.Context) Allocator.Error!Backend {
        return .{
            .allocator = allocator,
            .ctx = ctx,
        };
    }

    pub fn deinit(_: *Backend) void {}

    /// Lowers f64 `arith.exp`, `log`, `log1p`, `expm1`, `sin` and `cos` to calls of the `math`
    /// imports, which the caller promises to bind to correctly rounded routines. Unset, they
    /// stay refused.
    pub fn importMath(self: *Backend) void {
        self.math_imports = true;
    }

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
        const lowered = try self.lower(module);
        var limits = wasm.ModuleEmitter.Limits.inspect(lowered, options) catch |err| {
            return mapEmissionError(err);
        };
        limits.math_imports = self.math_imports;
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
        const lowered = try self.lower(module);
        var limits = wasm.ModuleEmitter.Limits.inspect(lowered, options) catch |err| {
            return mapEmissionError(err);
        };
        limits.math_imports = self.math_imports;
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

        var symbols = wasm.emission.symbols.Iterator.init(lowered, options) catch |err| {
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
        for (std.enums.values(wasm.emission.math.Function)) |function| {
            if (!self.math_imports or limits.facts.math.rank(function) == null) continue;
            artifact.linkage.addRequired(.{
                .name = @tagName(function),
                .kind = .function,
                .binding = .external,
            }) catch return error.OutOfMemory;
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
