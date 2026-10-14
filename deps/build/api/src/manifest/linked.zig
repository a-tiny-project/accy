const std = @import("std");
const manifest = @import("root.zig");

pub const maximum_compiles = manifest.model.maximum_compiles;
pub const maximum_depth = 64;
pub const maximum_references = manifest.model.maximum_references;

/// One immutable view after attachment isolates every participating compiler.
/// Dense IDs follow compiler discovery, sorted imports and original link slots.
pub const Plan = struct {
    build: *std.Build,
    excluded: []const *std.Build.Module,
    compiles: std.ArrayList(*std.Build.Step.Compile) = .empty,
    modules: std.ArrayList(*std.Build.Module) = .empty,
    compile_ids: std.AutoHashMapUnmanaged(*std.Build.Step.Compile, u32) = .empty,
    module_ids: std.AutoHashMapUnmanaged(*std.Build.Module, u32) = .empty,
    edges: [maximum_compiles][maximum_compiles]bool = @splat(@splat(false)),
    references: usize = 0,

    pub fn init(b: *std.Build, root: *std.Build.Step.Compile, excluded: []const *std.Build.Module) !Plan {
        var self = Plan{ .build = b, .excluded = excluded };
        _ = try self.appendCompile(root);
        var cursor: usize = 0;
        while (cursor < self.compiles.items.len) : (cursor += 1) try self.discover(@intCast(cursor));
        try self.checkCycles();
        return self;
    }

    pub fn derived(self: *const Plan, module: *std.Build.Module) bool {
        for (self.excluded) |item| if (item == module) return true;
        return manifest.attachment.isMarker(module);
    }

    fn appendCompile(self: *Plan, compile: *std.Build.Step.Compile) !u32 {
        if (self.compile_ids.get(compile)) |id| return id;
        if (compile.step.owner.graph != self.build.graph) return error.ForeignCompilerLinkedArtifact;
        if (self.compiles.items.len != 0 and (compile.kind != .obj or compile.use_llvm == null)) return error.UnqualifiedCompilerLinkedArtifact;
        if (self.compiles.items.len == maximum_compiles) return error.CompilerLinkedCountExceeded;
        const id: u32 = @intCast(self.compiles.items.len);
        try self.compiles.append(self.build.graph.arena, compile);
        try self.compile_ids.put(self.build.graph.arena, compile, id);
        return id;
    }

    fn appendModule(self: *Plan, module: *std.Build.Module) !u32 {
        if (self.module_ids.get(module)) |id| return id;
        if (self.modules.items.len == manifest.graph.maximum_modules) return error.CompilerModuleCountExceeded;
        if (module.owner.graph != self.build.graph) return error.ForeignCompilerModule;
        const id: u32 = @intCast(self.modules.items.len);
        try self.modules.append(self.build.graph.arena, module);
        try self.module_ids.put(self.build.graph.arena, module, id);
        return id;
    }

    fn reference(self: *Plan) !void {
        if (self.references == maximum_references) return error.CompilerReferenceCountExceeded;
        self.references += 1;
    }

    fn discover(self: *Plan, id: u32) !void {
        const allocator = self.build.graph.arena;
        const compile = self.compiles.items[id];
        var local: std.AutoArrayHashMapUnmanaged(*std.Build.Module, void) = .empty;
        defer local.deinit(allocator);
        try local.put(allocator, compile.root_module, {});
        _ = try self.appendModule(compile.root_module);
        var macros = false;
        var assembly = false;
        var cursor: usize = 0;
        while (cursor < local.count()) : (cursor += 1) {
            const module = local.keys()[cursor];
            if (module.import_table.count() > manifest.graph.maximum_imports) return error.CompilerImportCountExceeded;
            const names = try allocator.dupe([]const u8, module.import_table.keys());
            defer allocator.free(names);
            std.mem.sort([]const u8, names, {}, less);
            for (names) |name| {
                const imported = module.import_table.get(name).?;
                if (self.derived(imported)) continue;
                _ = try self.appendModule(imported);
                try local.put(allocator, imported, {});
            }
            macros = macros or module.c_macros.items.len != 0;
            if (module.link_objects.items.len > maximum_references) return error.CompilerReferenceCountExceeded;
            for (module.link_objects.items) |object| switch (object) {
                .other_step => |child| {
                    const child_id = try self.appendCompile(child);
                    self.edges[id][child_id] = true;
                },
                .assembly_file => assembly = true,
                else => {},
            };
        }
        if (assembly) {
            const target = compile.root_module.resolved_target orelse return error.UnqualifiedCompilerAssemblyTarget;
            if (target.result.os.tag != .linux or (target.result.cpu.arch != .x86_64 and target.result.cpu.arch != .aarch64)) return error.UnqualifiedCompilerAssemblyTarget;
            if (macros) return error.UnqualifiedCompilerAssemblyMacros;
            try assemblyEnvironment(self.build);
        }
    }

    /// White/gray/black traversal uses at most64 stack frames, before the
    /// generator adds any output dependency. Module import cycles are separate.
    pub fn checkCycles(self: *Plan) !void {
        var colors: [maximum_compiles]u2 = @splat(0);
        const Frame = struct { node: usize, next: usize = 0 };
        var stack: [maximum_depth]Frame = undefined;
        var length: usize = 1;
        stack[0] = .{ .node = 0 };
        colors[0] = 1;
        while (length != 0) {
            const frame = &stack[length - 1];
            if (frame.next == self.compiles.items.len) {
                colors[frame.node] = 2;
                length -= 1;
                continue;
            }
            const child = frame.next;
            frame.next += 1;
            if (!self.edges[frame.node][child]) continue;
            if (colors[child] == 1) return error.CompilerLinkedCycle;
            if (colors[child] == 2) continue;
            if (length == maximum_depth) return error.CompilerLinkedDepthExceeded;
            colors[child] = 1;
            stack[length] = .{ .node = child };
            length += 1;
        }
        for (self.modules.items) |module| {
            for (module.import_table.values()) |_| try self.reference();
            for (module.link_objects.items) |object| {
                if (object == .other_step) try self.reference();
            }
        }
    }
};

fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Maker clears per-file C flags before each assembly input. Module macros are
/// rejected across the whole local closure. The pinned compiler consumes these
/// native-path variables through NativePaths, never as arbitrary Clang flags.
/// Foreign capture subsequently retains every admitted path and invocation value.
fn assemblyEnvironment(b: *std.Build) !void {
    var present = false;
    var bytes: usize = 0;
    for ([_][]const u8{ "NIX_CFLAGS_COMPILE", "NIX_CFLAGS_LINK", "NIX_LDFLAGS" }) |name| {
        const value = b.graph.environ_map.get(name) orelse continue;
        if (value.len > manifest.binding.model.maximum_invocation_bytes - bytes) return error.UnqualifiedCompilerAssemblyEnvironment;
        bytes += value.len;
        present = true;
    }
    if (!present) return;
    const paths = try std.zig.system.NativePaths.detect(b.graph.arena, b.graph.io, &b.graph.host.result, &b.graph.environ_map);
    if (paths.warnings.items.len != 0) return error.UnqualifiedCompilerAssemblyEnvironment;
}
