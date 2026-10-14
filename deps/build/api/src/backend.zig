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

/// Pairs a compile's linker with its backend once the graph is complete, projections included.
/// LLD links only LLVM output, and the compiler refuses `-fno-llvm -flld`. A compile that links
/// and asks for LLD compiles through LLVM, even when its owner chose the native backend, and an
/// LLVM compile keeps LLD whether or not it links. A compile that links nothing on another backend
/// drops the request and keeps the backend selected for it. The outputs requested by finalization
/// decide: a binary requested later from such a native or default-backend compile links without
/// the LLD its owner asked for.
pub fn settleLinker(compile: *std.Build.Step.Compile) void {
    const settled = settledLinkage(compile.use_llvm, compile.use_lld, links(compile));
    compile.use_llvm = settled.use_llvm;
    compile.use_lld = settled.use_lld;
    if (compile.use_lld == true) std.debug.assert(compile.use_llvm == true);
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

const Linkage = struct {
    use_llvm: ?bool,
    use_lld: ?bool,
};

fn settledLinkage(use_llvm: ?bool, use_lld: ?bool, linking: bool) Linkage {
    if (use_lld != true) return .{ .use_llvm = use_llvm, .use_lld = use_lld };
    if (linking or use_llvm == true) return .{ .use_llvm = true, .use_lld = true };
    return .{ .use_llvm = use_llvm, .use_lld = null };
}

/// A compile links when it emits a binary or an import library. Otherwise the compiler runs with
/// `-fno-emit-bin`, as for every `check.project` copy, and links nothing.
fn links(compile: *const std.Build.Step.Compile) bool {
    return compile.generated_bin != .none or compile.generated_implib != .none;
}

fn expectSettled(selected: ?bool, use_lld: ?bool, linking: bool) !void {
    const settled = settledLinkage(selected, use_lld, linking);
    try std.testing.expect(settled.use_lld != true or settled.use_llvm == true);
    if (use_lld != true) {
        const unchanged: Linkage = .{ .use_llvm = selected, .use_lld = use_lld };
        try std.testing.expectEqual(unchanged, settled);
    } else if (linking) {
        const linked: Linkage = .{ .use_llvm = true, .use_lld = true };
        try std.testing.expectEqual(linked, settled);
    } else {
        const kept: ?bool = if (selected == true) true else null;
        try std.testing.expectEqual(selected, settled.use_llvm);
        try std.testing.expectEqual(kept, settled.use_lld);
    }
}
