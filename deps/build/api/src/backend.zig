const std = @import("std");
const target = @import("target.zig");

pub const Product = enum {
    native,
    llvm,
};

pub const option = "product-backend";

pub const RawCompileOptions = struct {
    owner: ?Product = null,
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,
    plugin_witness: bool = false,
};

pub const RawCompileSelection = struct {
    use_llvm: ?bool = null,
    target_triple: ?[]const u8 = null,

    pub fn flag(self: RawCompileSelection) ?[]const u8 {
        if (self.use_llvm) |llvm| {
            return if (llvm) "-fllvm" else "-fno-llvm";
        }
        return null;
    }

    pub fn applyRun(self: RawCompileSelection, run: *std.Build.Step.Run) void {
        if (self.flag()) |backend_flag| {
            run.addArg(backend_flag);
        }
        if (self.target_triple) |triple| {
            std.debug.assert(triple.len > 0);
            run.addArgs(&.{ "-target", triple });
        }
    }
};

pub fn configured(b: *std.Build) ?Product {
    if (b.available_options_map.contains(option)) {
        const input = b.user_input_options.get(option) orelse return null;
        return switch (input) {
            .scalar => |value| std.meta.stringToEnum(Product, value),
            else => null,
        };
    }
    return b.option(
        Product,
        option,
        "Compiler backend for package product and test artifacts without an " ++
            "owner override (default: native for supported host Debug artifacts)",
    );
}

pub fn apply(
    b: *std.Build,
    requested: ?Product,
    compile: *std.Build.Step.Compile,
) void {
    const owner_backend: ?bool = if (compile.use_llvm) |explicit|
        explicit
    else if (compile.generated_llvm_ir != .none or
        compile.generated_llvm_bc != .none)
        true
    else
        null;
    compile.use_llvm = selectedUseLlvm(
        owner_backend,
        requested,
        ordinaryHostDebug(b, compile),
    );
}

pub fn selectRaw(
    b: *std.Build,
    options: RawCompileOptions,
) RawCompileSelection {
    const requested = configured(b);
    const host_native = ordinaryHostTarget(b, options.target);
    const use_llvm = evaluateRaw(
        options.owner,
        requested,
        host_native,
        options.optimize,
        options.plugin_witness,
    );
    const target_triple: ?[]const u8 = if (options.target) |resolved|
        if (target.eql(resolved, b.graph.host))
            null
        else
            nonHostTargetTriple(b, resolved)
    else
        null;
    return .{
        .use_llvm = use_llvm,
        .target_triple = target_triple,
    };
}

pub fn evaluateRaw(
    owner: ?Product,
    requested: ?Product,
    host_native: bool,
    optimize: ?std.builtin.OptimizeMode,
    plugin_witness: bool,
) ?bool {
    if (owner) |explicit| {
        return explicit == .llvm;
    }
    if (requested == .llvm) return true;
    if (requested == .native) {
        return if (host_native) false else null;
    }
    if (plugin_witness) {
        return if (host_native) false else null;
    }
    if (optimize) |opt| {
        if (opt == .debug and host_native) return false;
    }
    return null;
}

pub fn ordinaryHostTarget(
    b: *std.Build,
    resolved_target: ?std.Build.ResolvedTarget,
) bool {
    const resolved = resolved_target orelse b.graph.host;
    if (!target.eql(resolved, b.graph.host)) return false;
    return supportedNativeTarget(resolved.result);
}

fn nonHostTargetTriple(
    b: *std.Build,
    resolved_target: std.Build.ResolvedTarget,
) []const u8 {
    if (!resolved_target.query.isNative()) {
        if (resolved_target.query.zigTriple(b.graph.arena)) |triple| {
            if (triple.len > 0) return triple;
        } else |_| {}
    }
    const full_query = target.query(resolved_target);
    return full_query.zigTriple(b.graph.arena) catch @panic("OOM");
}

fn ordinaryHostDebug(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
) bool {
    const root = compile.root_module;
    const optimize = root.optimize orelse return false;
    if (optimize != .debug) return false;
    const resolved = root.resolved_target orelse return false;
    if (!ordinaryHostTarget(b, resolved)) return false;
    if (moduleUsesThreadSanitizer(b, root)) return false;
    if (compile.kind == .lib and
        compile.linkage == .dynamic and
        resolved.result.os.tag.isDarwin())
    {
        return false;
    }
    if (compile.generated_llvm_ir != .none or
        compile.generated_llvm_bc != .none)
    {
        return false;
    }
    if (compile.lto != null and compile.lto != .none) return false;
    return true;
}

/// Returns the backend for a tool or test that runs on the build host: the self-hosted backend
/// where `supportedNativeTarget` admits the host, and the compiler default elsewhere. Validation
/// suites and native qualification projections keep an explicit pin instead, because their
/// evidence records the native backend and `validation/verify.zig` refuses an LLVM compile.
pub fn hostTool(b: *std.Build) ?bool {
    return if (supportedNativeTarget(b.graph.host.result)) false else null;
}

/// Admits x86_64 ELF only. The pinned self-hosted x86_64 backend emits Mach-O executables that
/// dyld refuses (`segment '__CONST_ZIG' vm address out of order`) or that panic on misaligned
/// heap allocations, and the stage2 AArch64 backend allocates without bound.
fn supportedNativeTarget(value: std.Target) bool {
    if (value.cpu.arch != .x86_64) return false;
    if (value.ptrBitWidth() != 64) return false;
    if (value.os.tag == .illumos or value.os.tag.isBSD()) return false;
    return value.ofmt == .elf;
}

fn moduleUsesThreadSanitizer(
    b: *std.Build,
    root: *std.Build.Module,
) bool {
    var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    return moduleClosureUsesThreadSanitizer(b, &visited, root);
}

fn moduleClosureUsesThreadSanitizer(
    b: *std.Build,
    visited: *std.AutoHashMapUnmanaged(*std.Build.Module, void),
    module: *std.Build.Module,
) bool {
    const entry = visited.getOrPut(b.graph.arena, module) catch @panic("OOM");
    if (entry.found_existing) return false;
    if (module.sanitize_thread == true) return true;
    for (module.import_table.values()) |imported| {
        if (moduleClosureUsesThreadSanitizer(b, visited, imported)) return true;
    }
    return false;
}

fn selectedUseLlvm(
    owner: ?bool,
    requested: ?Product,
    ordinary_host_debug: bool,
) ?bool {
    if (owner) |use_llvm| return use_llvm;
    if (requested == .llvm) return true;
    if (ordinary_host_debug) return false;
    return null;
}

test "ordinary host Debug artifacts select the native backend" {
    try std.testing.expectEqual(
        false,
        selectedUseLlvm(null, null, true),
    );
    try std.testing.expectEqual(
        null,
        selectedUseLlvm(null, null, false),
    );
}

test "artifact owners retain their compiler backend" {
    try std.testing.expectEqual(
        true,
        selectedUseLlvm(true, .native, true),
    );
    try std.testing.expectEqual(
        false,
        selectedUseLlvm(false, .llvm, true),
    );
}

test "explicit product backend controls otherwise unspecified artifacts" {
    try std.testing.expectEqual(
        false,
        selectedUseLlvm(null, .native, true),
    );
    try std.testing.expectEqual(
        null,
        selectedUseLlvm(null, .native, false),
    );
    try std.testing.expectEqual(
        true,
        selectedUseLlvm(null, .llvm, true),
    );
}

test "tool backend follows product policy without forcing native on unsupported hosts" {
    try std.testing.expectEqual(false, selectedUseLlvm(null, .native, true));
    try std.testing.expectEqual(null, selectedUseLlvm(null, .native, false));
    try std.testing.expectEqual(true, selectedUseLlvm(null, .llvm, false));
}

test "native target support matches the pinned Debug policy" {
    const builtin = @import("builtin");
    const host_supported = supportedNativeTarget(builtin.target);
    try std.testing.expectEqual(
        builtin.target.cpu.arch == .x86_64 and
            builtin.target.ofmt == .elf and
            builtin.target.os.tag != .illumos and
            !builtin.target.os.tag.isBSD(),
        host_supported,
    );
}

test "raw backend evaluation follows product policy without forcing native on unsupported hosts" {
    try std.testing.expectEqual(false, evaluateRaw(null, null, true, .debug, false));
    try std.testing.expectEqual(null, evaluateRaw(null, null, false, .debug, false));
    try std.testing.expectEqual(false, evaluateRaw(null, null, true, .fast, true));
    try std.testing.expectEqual(null, evaluateRaw(null, null, false, .fast, true));
    try std.testing.expectEqual(true, evaluateRaw(null, .llvm, true, .fast, true));
    try std.testing.expectEqual(true, evaluateRaw(null, .llvm, false, .debug, false));
    try std.testing.expectEqual(false, evaluateRaw(null, .native, true, .fast, false));
    try std.testing.expectEqual(null, evaluateRaw(null, .native, false, .fast, false));
    try std.testing.expectEqual(false, evaluateRaw(.native, .llvm, false, .fast, false));
    try std.testing.expectEqual(true, evaluateRaw(.llvm, .native, true, .fast, true));
}

test "raw compile selection formats compiler backend flags" {
    const native_sel = RawCompileSelection{ .use_llvm = false };
    try std.testing.expectEqualStrings("-fno-llvm", native_sel.flag().?);

    const llvm_sel = RawCompileSelection{ .use_llvm = true };
    try std.testing.expectEqualStrings("-fllvm", llvm_sel.flag().?);

    const default_sel = RawCompileSelection{ .use_llvm = null };
    try std.testing.expectEqual(null, default_sel.flag());
}

test "selectRaw and applyRun configure raw run step argv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = std.Options.debug_io,
        .arena = allocator,
        .zig_exe = "zig",
        .environ_map = .init(allocator),
        .host = .{ .query = .{}, .result = @import("builtin").target },
        .generated_files = .empty,
        .wip_configuration = .init(allocator),
    };
    const b = try std.Build.create(graph, .cwd(), &.{});

    const witness_sel = selectRaw(b, .{
        .plugin_witness = true,
        .optimize = .fast,
    });
    const run_witness = b.addSystemCommand(&.{ "zig", "test" });
    witness_sel.applyRun(run_witness);
    if (ordinaryHostTarget(b, null)) {
        try std.testing.expectEqualStrings("-fno-llvm", witness_sel.flag().?);
        try std.testing.expect(witness_sel.target_triple == null);
        try std.testing.expectEqualStrings("-fno-llvm", run_witness.argv.items[2].bytes);
    }

    const llvm_sel = selectRaw(b, .{
        .owner = .llvm,
        .plugin_witness = true,
    });
    try std.testing.expectEqualStrings("-fllvm", llvm_sel.flag().?);
    const run_llvm = b.addSystemCommand(&.{ "zig", "test" });
    llvm_sel.applyRun(run_llvm);
    try std.testing.expectEqualStrings("-fllvm", run_llvm.argv.items[2].bytes);

    const aarch64_query = try std.Target.Query.parse(.{ .arch_os_abi = "aarch64-linux" });
    const nonhost_target = std.Build.ResolvedTarget{
        .query = aarch64_query,
        .result = try std.zig.system.resolveTargetQuery(std.testing.io, aarch64_query),
    };
    const nonhost_sel = selectRaw(b, .{
        .target = nonhost_target,
        .plugin_witness = true,
    });
    try std.testing.expect(nonhost_sel.flag() == null);
    try std.testing.expect(nonhost_sel.target_triple != null);
    const run_nonhost = b.addSystemCommand(&.{ "zig", "test" });
    nonhost_sel.applyRun(run_nonhost);
    try std.testing.expectEqualStrings("-target", run_nonhost.argv.items[2].bytes);
    try std.testing.expectEqualStrings("aarch64-linux", run_nonhost.argv.items[3].bytes);
}
