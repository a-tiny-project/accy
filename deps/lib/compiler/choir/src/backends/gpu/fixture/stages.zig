//! The vertex and fragment modules every stage emitter reads, the compute
//! kernels the SPIR-V validation gate checks beside them, and the one walk over
//! a module that bounds what emitting it can cost. The emitter tests and the
//! gate share these, so the gate validates exactly what the tests check.

const std = @import("std");
const choir = @import("../../../root.zig");
const backends_gpu = @import("../root.zig");
const gpu = @import("../../../dialects/gpu/root.zig");

const ir = choir.ir;

pub const Context = ir.Context;
pub const Limits = ir.Context.Limits;

/// A module holding one vertex and one fragment entry.
pub const Case = struct {
    name: []const u8,
    source: []const u8,
    vertex: []const u8,
    fragment: []const u8,
};

pub const cases = [_]Case{
    .{
        .name = "textured",
        .source = @embedFile("textured.txt"),
        .vertex = "textured_vertex",
        .fragment = "textured_fragment",
    },
    .{
        .name = "indexed",
        .source = @embedFile("indexed.txt"),
        .vertex = "indexed_vertex",
        .fragment = "indexed_fragment",
    },
    .{
        .name = "pushed",
        .source = @embedFile("pushed.txt"),
        .vertex = "pushed_vertex",
        .fragment = "pushed_fragment",
    },
    .{
        .name = "element",
        .source = @embedFile("element.txt"),
        .vertex = "element_vertex",
        .fragment = "element_fragment",
    },
};

pub const alloca_case: Case = .{
    .name = "alloca",
    .source = @embedFile("alloca.txt"),
    .vertex = "alloca_vertex",
    .fragment = "alloca_fragment",
};

/// The fragment keeps the multiply and following add separate for a raster witness.
/// Its push values keep every nonzero operand and intermediate normal.
pub const contraction_case: Case = .{
    .name = "contraction",
    .source = @embedFile("contraction.txt"),
    .vertex = "contraction_vertex",
    .fragment = "contraction_fragment",
};

/// Takes dpdx and dpdy of frag_coord's x times y over 64, and dpdx and fwidth of a varying. The
/// vertex stage scales its position by w, its second texture coordinate, so the triangle keeps
/// its place on screen and the varying interpolates in perspective whenever w differs. A second
/// fragment entry, `gradient_call_fragment`, takes the same derivatives of helper results: the
/// product scaled by `gradient_scaled`, and twice the varying from `gradient_twice`, which passes
/// it through a local array.
pub const gradient_case: Case = .{
    .name = "gradient",
    .source = @embedFile("gradient.txt"),
    .vertex = "gradient_vertex",
    .fragment = "gradient_fragment",
};

/// The `gradient` module with its other fragment entry, whose derivatives read helper results. An
/// MSL source holds one vertex and one fragment entry, so Metal draws this entry from its own
/// source, and SPIR-V and the CPU twin draw it from the `gradient` module.
pub const gradient_call_case: Case = .{
    .name = "gradient-call",
    .source = gradient_case.source,
    .vertex = gradient_case.vertex,
    .fragment = "gradient_call_fragment",
};

pub const calls_case: Case = .{
    .name = "calls",
    .source = @embedFile("calls.txt"),
    .vertex = "calls_vertex",
    .fragment = "calls_fragment",
};

/// A module holding compute kernels, which the SPIR-V validation gate checks
/// beside the stage modules.
pub const Kernel = struct {
    name: []const u8,
    source: []const u8,
};

/// Between them these kernels bind storage buffers, read push constants, read
/// the invocation builtins, declare a workgroup shape, and raise the module to
/// SPIR-V 1.3 through subgroup operations.
pub const kernels = [_]Kernel{
    .{ .name = "remainder", .source = @embedFile("remainder.txt") },
    .{ .name = "shaped", .source = @embedFile("shaped.txt") },
    .{ .name = "shapes", .source = @embedFile("shapes.txt") },
    .{ .name = "scalars", .source = @embedFile("scalars.txt") },
    .{ .name = "subgroup", .source = @embedFile("subgroup.txt") },
};

/// The oldest Vulkan environment whose SPIR-V covers `version`, the header's
/// second word. A module is validated under it, so a rule of any later Vulkan
/// cannot hide a finding its version must meet.
pub fn spirvValEnvironment(version: u32) error{UnsupportedSpirvVersion}![]const u8 {
    const Version = backends_gpu.spirv.emitter.Version;
    return switch (version) {
        Version.v10 => "vulkan1.0",
        Version.v10 + 1...Version.v13 => "vulkan1.1",
        else => error.UnsupportedSpirvVersion,
    };
}

/// A parsed and verified module and the context that owns it. It holds its
/// context in place, so it lives where its caller put it.
pub const Session = struct {
    ctx: ir.Context,
    module: *ir.Operation,

    /// Parses `source` and runs the SPIR-V lowering when `lowered`.
    pub fn init(
        self: *Session,
        allocator: std.mem.Allocator,
        limits: Limits,
        source: []const u8,
        lowered: bool,
    ) !void {
        self.ctx = try ir.Context.init(allocator, limits);
        errdefer self.ctx.deinit(allocator);
        try backends_gpu.registration.prepareCompilationDialects(&self.ctx);
        self.module = try ir.parse.operation(&self.ctx, source);
        errdefer self.module.erase();
        try ir.verifyOperation(self.module, .{});
        if (!lowered) return;
        var pm = choir.passes.PassManager.init(allocator);
        defer pm.deinit();
        pm.enableVerifier();
        try backends_gpu.lowering.addTargetLoweringPipeline(&pm, .spirv);
        if (pm.run(self.module, &self.ctx) != .success) return error.LoweringFailed;
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        self.module.erase();
        self.ctx.deinit(allocator);
    }
};

/// SPIR-V words for a lowered module. The caller owns them.
pub fn emitSpirv(allocator: std.mem.Allocator, module: *ir.Operation) ![]u32 {
    var codegen = backends_gpu.spirv.emitter.SpirvCodegen.init(allocator);
    defer codegen.deinit();
    return codegen.emitModuleWords(module);
}

/// An x86_64 relocatable object holding the case's stages as host functions over
/// `gpu_abi.stage`. A module the CPU lowering refuses names the op in `refusal`. The caller
/// owns the bytes.
pub fn emitCpuObject(
    allocator: std.mem.Allocator,
    module: *ir.Operation,
    case: Case,
    refusal: *backends_gpu.cpu.StageRefusal,
) ![]u8 {
    if (comptime !@hasDecl(choir.backends.x86_64, "backend")) {
        refusal.operation = "x86_64 backend";
        return error.UnsupportedOperation;
    }
    const host = try backends_gpu.cpu.lowerStagesToHost(allocator, module, refusal);
    defer host.erase();
    var backend = try choir.backends.x86_64.backend.Backend.init(allocator, module.getContext());
    defer backend.deinit();
    var object = try backend.compileModuleToObjectFile(host, case.vertex);
    defer object.deinit();
    if (object.payload.buffers.items.len != 1) return error.InvalidArtifact;
    return allocator.dupe(u8, object.payload.buffers.items[0].bytes);
}

/// Writes `<case>.push` into `dir`: the decimal count of push-constant bytes `module`'s stages
/// read, which a render pipeline drawing the module must declare. Each stage writer puts it beside
/// the payload it emits from the same module, so a witness reports it with the artifact.
pub fn writePushExtent(io: std.Io, dir: std.Io.Dir, case: Case, module: *ir.Operation) !void {
    const extent = gpu.stage.pushExtent(module) orelse return error.InvalidArtifact;
    var name_buffer: [64]u8 = undefined;
    var text_buffer: [16]u8 = undefined;
    try dir.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&name_buffer, "{s}.push", .{case.name}),
        .data = try std.fmt.bufPrint(&text_buffer, "{d}\n", .{extent}),
    });
}

/// MSL source for the case's two entries. The caller owns it.
pub fn emitMsl(allocator: std.mem.Allocator, module: *ir.Operation, case: Case) ![]u8 {
    return backends_gpu.metal.msl.emitMslRender(allocator, module, .{
        .vertex = case.vertex,
        .fragment = case.fragment,
    });
}

/// Builds a hand-written `spirv.module` with an empty vertex entry named
/// `dialect_vertex` and an empty fragment entry named `dialect_fragment`, the
/// stage path that bypasses the gpu dialect.
pub fn buildDialectModule(ctx: *ir.Context) !*ir.Operation {
    const SpirvDialect = backends_gpu.spirv.SpirvDialect;
    const ReturnOp = choir.dialects.func.FuncDialect.ReturnOp;
    try backends_gpu.registration.prepareCompilationDialects(ctx);
    const module = try SpirvDialect.ModuleOp.create(
        ctx,
        .unknown,
        .logical,
        .glsl450,
        .shader,
        "GLSL.std.450",
    );
    errdefer module.op.erase();
    const entries = [_]struct { name: []const u8, model: backends_gpu.spirv.ExecutionModel }{
        .{ .name = "dialect_vertex", .model = .vertex },
        .{ .name = "dialect_fragment", .model = .fragment },
    };
    for (entries) |entry| {
        var func = try SpirvDialect.FuncOp.create(ctx, .unknown, entry.name, &.{}, &.{});
        try func.setEntryPoint(ctx, entry.model);
        try module.getBodyBlock().addOperation(func.op);
        const ret = try ReturnOp.create(ctx, .unknown, &.{});
        try func.getEntryBlock().addOperation(ret.op);
    }
    return module.op;
}

/// Blocks a walk holds pending at once. Stage modules nest a few levels.
pub const walk_capacity = 64;

/// Visits every op in `module` once, reading each op's name and operand
/// count, and returns how many ops it saw. Every emitter reads at least this
/// much, so its time is the floor an emitter's time is measured against.
pub fn walk(module: *ir.Operation) !u64 {
    var pending: [walk_capacity]*ir.Block = undefined;
    var count: usize = 0;
    var ops: u64 = 0;
    var bytes: u64 = 0;
    try pushBlocks(module, &pending, &count);
    while (count > 0) {
        count -= 1;
        var cursor = pending[count].operations.head;
        while (cursor) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            ops += 1;
            bytes += op.name.name.len + op.getNumOperands();
            try pushBlocks(op, &pending, &count);
            cursor = op.next_op;
        }
    }
    std.mem.doNotOptimizeAway(bytes);
    return ops;
}

fn pushBlocks(op: *ir.Operation, pending: *[walk_capacity]*ir.Block, count: *usize) !void {
    for (0..op.getNumRegions()) |index| {
        const region = op.getRegion(index) orelse continue;
        var blocks = region.getBlocks();
        while (blocks.next()) |block| {
            if (count.* == walk_capacity) return error.WalkCapacityExceeded;
            pending[count.*] = block;
            count.* += 1;
        }
    }
}
