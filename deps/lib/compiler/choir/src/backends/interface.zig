const std = @import("std");
const ir = @import("../core/root.zig");

const Allocator = std.mem.Allocator;

pub const BackendError = error{
    UnsupportedArchitecture,
    UnsupportedOperation,
    FunctionNotFound,
    CodeGenFailed,
    VerificationFailed,
    OutOfMemory,
};

pub const BackendTarget = struct {
    name: []const u8,
    kind: Kind,

    pub const Kind = enum {
        cpu,
        module,
        external,
    };

    pub const aarch64 = BackendTarget{ .name = "aarch64", .kind = .cpu };
    pub const x86_64 = BackendTarget{ .name = "x86_64", .kind = .cpu };
    pub const wasm = BackendTarget{ .name = "wasm", .kind = .module };

    pub fn external(name: []const u8) BackendTarget {
        return .{ .name = name, .kind = .external };
    }

    pub fn eql(self: BackendTarget, other: BackendTarget) bool {
        return self.kind == other.kind and std.mem.eql(u8, self.name, other.name);
    }
};

pub const BackendCapabilities = struct {
    module: ModuleCapabilities = .{},
    artifact: ArtifactCapabilities = .{},
    cpu: CpuCapabilities = .{},

    pub const ModuleCapabilities = struct {
        verify: bool = true,
        lower: bool = true,
    };

    pub const ArtifactCapabilities = struct {
        machine_code: bool = false,
        object_file: bool = false,
        webassembly_module: bool = false,
        source_text: bool = false,
    };

    pub const CpuCapabilities = struct {
        disassemble: bool = false,
    };
};

pub const LowerOptions = struct {
    verify: bool = true,
};

pub const EmitOptions = struct {
    entry: ?[]const u8 = null,
};

pub const LifecycleVTable = struct {
    deinit: *const fn (*anyopaque, Allocator) void,
};

pub const ModuleVTable = struct {
    verify: *const fn (*anyopaque, *ir.Operation) BackendError!void,
    lower: *const fn (*anyopaque, *ir.Operation, LowerOptions) BackendError!*ir.Operation,
    emit: *const fn (*anyopaque, *ir.Operation, EmitOptions, *std.Io.Writer) BackendError!void,
};

pub const DebugVTable = struct {
    disassemble: *const fn (*anyopaque, []const u8, *std.Io.Writer) BackendError!void,
};

pub const BackendHandle = struct {
    allocator: Allocator,
    target: BackendTarget,
    name: []const u8,
    capabilities: BackendCapabilities,
    ptr: *anyopaque,
    lifecycle: *const LifecycleVTable,
    module: *const ModuleVTable,
    debug: ?*const DebugVTable = null,

    pub fn deinit(self: *BackendHandle) void {
        self.lifecycle.deinit(self.ptr, self.allocator);
    }

    pub fn verify(self: *BackendHandle, module: *ir.Operation) BackendError!void {
        return self.module.verify(self.ptr, module);
    }

    pub fn lowerModule(self: *BackendHandle, module: *ir.Operation, options: LowerOptions) BackendError!*ir.Operation {
        return self.module.lower(self.ptr, module, options);
    }

    pub fn emit(self: *BackendHandle, module: *ir.Operation, options: EmitOptions, writer: *std.Io.Writer) BackendError!void {
        return self.module.emit(self.ptr, module, options, writer);
    }

    pub fn disassemble(self: *BackendHandle, code: []const u8, writer: *std.Io.Writer) BackendError!void {
        const debug = self.debug orelse return BackendError.UnsupportedArchitecture;
        return debug.disassemble(self.ptr, code, writer);
    }
};

pub fn assertModuleBackend(comptime BackendType: type) void {
    comptime {
        if (!@hasDecl(BackendType, "init")) @compileError("backend missing init");
        assertInitShape(BackendType);
        if (!@hasDecl(BackendType, "deinit")) @compileError("backend missing deinit");
        if (!@hasDecl(BackendType, "verify")) @compileError("backend missing verify");
        if (!@hasDecl(BackendType, "lower")) @compileError("backend missing lower");
        if (!@hasDecl(BackendType, "emit")) @compileError("backend missing emit");
    }
}

pub fn assertDebugBackend(comptime BackendType: type) void {
    comptime {
        if (!@hasDecl(BackendType, "disassemble")) @compileError("backend missing disassemble");
    }
}

pub fn initHandle(
    comptime BackendType: type,
    allocator: Allocator,
    ctx: *ir.Context,
    target: BackendTarget,
    name: []const u8,
    capabilities: BackendCapabilities,
) BackendError!BackendHandle {
    assertModuleBackend(BackendType);
    const has_debug = comptime hasDebugBackend(BackendType);

    if (capabilities.cpu.disassemble and !has_debug) {
        return BackendError.UnsupportedArchitecture;
    }

    const backend_ptr = allocator.create(BackendType) catch return BackendError.OutOfMemory;
    errdefer allocator.destroy(backend_ptr);
    backend_ptr.* = try BackendType.init(allocator, ctx);

    return .{
        .allocator = allocator,
        .target = target,
        .name = name,
        .capabilities = capabilities,
        .ptr = backend_ptr,
        .lifecycle = lifecycleVTableFor(BackendType),
        .module = moduleVTableFor(BackendType),
        .debug = if (has_debug and capabilities.cpu.disassemble) debugVTableFor(BackendType) else null,
    };
}

fn hasDebugBackend(comptime BackendType: type) bool {
    return @hasDecl(BackendType, "disassemble");
}

/// Asserts `init` takes what `initHandle` passes it. Checking the shape rather than the name makes
/// a changed constructor a compile error against this contract, instead of one inside the generic
/// call in `initHandle`, which names no backend a reader would recognize.
fn assertInitShape(comptime BackendType: type) void {
    const params = @typeInfo(@TypeOf(BackendType.init)).@"fn".param_types;
    if (params.len != 2) @compileError("a backend's init takes an allocator and a context");
}

fn lifecycleVTableFor(comptime BackendType: type) *const LifecycleVTable {
    const VTable = struct {
        fn deinit(ptr: *anyopaque, allocator: Allocator) void {
            const backend: *BackendType = @ptrCast(@alignCast(ptr));
            backend.deinit();
            allocator.destroy(backend);
        }
    };

    return &LifecycleVTable{ .deinit = VTable.deinit };
}

fn moduleVTableFor(comptime BackendType: type) *const ModuleVTable {
    const VTable = struct {
        fn verify(ptr: *anyopaque, module: *ir.Operation) BackendError!void {
            const backend: *BackendType = @ptrCast(@alignCast(ptr));
            return backend.verify(module);
        }

        fn lower(ptr: *anyopaque, module: *ir.Operation, options: LowerOptions) BackendError!*ir.Operation {
            const backend: *BackendType = @ptrCast(@alignCast(ptr));
            if (options.verify) {
                try backend.verify(module);
            }
            return backend.lower(module);
        }

        fn emit(ptr: *anyopaque, module: *ir.Operation, options: EmitOptions, writer: *std.Io.Writer) BackendError!void {
            const backend: *BackendType = @ptrCast(@alignCast(ptr));
            return backend.emit(module, options, writer);
        }
    };

    return &ModuleVTable{
        .verify = VTable.verify,
        .lower = VTable.lower,
        .emit = VTable.emit,
    };
}

fn debugVTableFor(comptime BackendType: type) *const DebugVTable {
    const VTable = struct {
        fn disassemble(ptr: *anyopaque, code: []const u8, writer: *std.Io.Writer) BackendError!void {
            const backend: *BackendType = @ptrCast(@alignCast(ptr));
            return backend.disassemble(code, writer);
        }
    };

    return &DebugVTable{
        .disassemble = VTable.disassemble,
    };
}

const ModuleOnlyBackend = struct {
    pub fn init(_: Allocator, _: *ir.Context) Allocator.Error!ModuleOnlyBackend {
        return .{};
    }

    pub fn deinit(_: *ModuleOnlyBackend) void {}

    pub fn verify(_: *ModuleOnlyBackend, _: *ir.Operation) BackendError!void {}

    pub fn lower(_: *ModuleOnlyBackend, module: *ir.Operation) BackendError!*ir.Operation {
        return module;
    }

    pub fn emit(_: *ModuleOnlyBackend, _: *ir.Operation, _: EmitOptions, _: *std.Io.Writer) BackendError!void {}
};

test "module backend handle does not require debug services" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try @import("../dialects/root.zig").registerAllDialects(&ctx);

    var handle = try initHandle(
        ModuleOnlyBackend,
        std.testing.allocator,
        &ctx,
        BackendTarget.external("test.module"),
        "module-only",
        .{ .artifact = .{ .source_text = true } },
    );
    defer handle.deinit();

    try std.testing.expect(handle.debug == null);
    try std.testing.expectError(BackendError.UnsupportedArchitecture, handle.disassemble(&.{}, undefined));
}

test "backend handle rejects unsupported claimed debug services" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try @import("../dialects/root.zig").registerAllDialects(&ctx);

    try std.testing.expectError(
        BackendError.UnsupportedArchitecture,
        initHandle(
            ModuleOnlyBackend,
            std.testing.allocator,
            &ctx,
            BackendTarget.external("test.module"),
            "module-only",
            .{ .cpu = .{ .disassemble = true } },
        ),
    );
}
