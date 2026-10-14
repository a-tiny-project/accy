const std = @import("std");
const native = @import("../root.zig").model;

pub const schema = "tiny.compiled-binding/v1";
pub const maximum_bindings = 64;
pub const maximum_registry_paths = 4096;
pub const maximum_record_bytes = 32 * 1024;
pub const maximum_invocation_bytes = 64 * 1024;
/// The emit binary's make-time mode, which verifies the live invocation
/// against the record a qualified configuration embedded.
pub const verify_invocation_command = "verify-invocation";
pub const maximum_manifest_bytes = native.maximum_manifest_bytes;
pub const maximum_compilation_bytes = 4 * 1024 * 1024;
pub const maximum_path_bytes = 4096;
pub const maximum_name_bytes = 256;
/// Bound streamed artifact I/O, using the fixed 64 KiB buffer below. Native Debug ELF
/// files contain linker growth space and stale placements beyond their live sections;
/// allow that layout without claiming an allocation proportional to the file bound.
pub const maximum_binary_bytes: u64 = 2 * 1024 * 1024 * 1024;
pub const stream_bytes = 64 * 1024;
pub const scratch_bytes = 32 * 1024 * 1024;

pub fn exportedBytesMax() usize {
    return maximum_record_bytes + maximum_invocation_bytes + maximum_manifest_bytes + maximum_compilation_bytes;
}

pub const Identity = struct {
    path: []const u8,
    bytes: u64,
    sha256: [64]u8,
};

pub const Compiler = struct {
    name: []const u8,
    kind: []const u8,
};

pub const Record = struct {
    schema: []const u8 = schema,
    status: enum { qualified, refused },
    refusal: ?[]const u8,
    compile: Compiler,
    binary: Identity,
    manifest: ?Identity,
    invocation: ?Identity,
    compilation: ?Identity,
};

pub const Payload = struct {
    manifest: []const u8,
    invocation: []const u8,
    compilation: []const u8,
};

pub fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

pub fn path(value: []const u8) !void {
    if (value.len == 0 or value.len > maximum_path_bytes or value[0] != '/') {
        return error.InvalidCompilerBindingPath;
    }
    for (value) |byte| if (byte < 32 or byte == 127) return error.InvalidCompilerBindingPath;
}

pub fn compiler(value: Compiler) !void {
    if (value.name.len == 0 or value.name.len > maximum_name_bytes) {
        return error.CompilerBindingNameTooLarge;
    }
    const kinds = [_][]const u8{ "exe", "lib", "obj", "test", "test_obj" };
    for (kinds) |kind| if (std.mem.eql(u8, kind, value.kind)) return;
    return error.InvalidCompilerBindingKind;
}

/// Validate the exact raw owner bytes against their entries in the native
/// manifest. Parsing borrows the bounded input bytes where possible.
pub fn validate(allocator: std.mem.Allocator, expected: Compiler, payload: Payload) !void {
    try compiler(expected);
    if (payload.manifest.len > maximum_manifest_bytes or
        payload.compilation.len > maximum_compilation_bytes or
        payload.invocation.len > maximum_invocation_bytes)
    {
        return error.CompilerBindingLeafTooLarge;
    }
    const entries = try native.decode(allocator, payload.manifest);
    defer allocator.free(entries);
    try matches(entries, "invocation.json", payload.invocation);
    try matches(entries, "compilations/0/compilation.json", payload.compilation);

    try compilation(allocator, expected, payload.compilation, entries);
    const Invocation = struct {
        schema: []const u8,
        binding: struct { compiler: []const u8, directory: []const u8, build_file: []const u8 },
    };
    const invocation = try std.json.parseFromSlice(Invocation, allocator, payload.invocation, .{
        .ignore_unknown_fields = true,
        .max_value_len = maximum_invocation_bytes,
    });
    defer invocation.deinit();
    if (!std.mem.eql(u8, invocation.value.schema, "tiny.compiler-invocation/v1")) {
        return error.CompilerBindingInvocationMismatch;
    }
    try path(invocation.value.binding.directory);
    try path(invocation.value.binding.build_file);
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.path, "toolchain/zig")) continue;
        if (entry.pinned_source.len == 0 or
            !std.mem.eql(u8, entry.pinned_source, invocation.value.binding.compiler))
        {
            return error.CompilerBindingToolchainMismatch;
        }
        return;
    }
    return error.CompilerBindingToolchainMissing;
}

/// Historical v1 keeps its genuine root record. v2 has a dense producing DAG;
/// a version label never substitutes one shape for the other.
fn compilation(allocator: std.mem.Allocator, expected: Compiler, bytes: []const u8, entries: []const native.Entry) !void {
    const Node = struct {
        id: u32,
        root_module: u32,
        compile: Compiler,
        output: ?struct { file: struct { input: []const u8, origin: []const u8 }, path: []const u8 },
    };
    const Module = struct {
        id: u32,
        imports: []const struct { module: ?u32 = null, derived: ?[]const u8 = null },
        link_objects: []const struct { other_step: ?struct { compile: u32 } = null },
    };
    const Header = struct {
        schema: []const u8,
        compile: ?Compiler = null,
        root: ?u32 = null,
        compiles: ?[]const Node = null,
        modules: ?[]const Module = null,
    };
    const parsed = try std.json.parseFromSlice(Header, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const value = parsed.value;
    if (std.mem.eql(u8, value.schema, "tiny.compilation/v1")) {
        const owner = value.compile orelse return error.CompilerBindingCompilationMismatch;
        if (value.root != null or value.compiles != null) return error.CompilerBindingCompilationMismatch;
        try sameCompiler(expected, owner);
    } else if (std.mem.eql(u8, value.schema, "tiny.compilation/v2")) {
        if (value.compile != null or value.root != 0) return error.CompilerBindingCompilationMismatch;
        const graph = .{
            .compiles = value.compiles orelse return error.CompilerBindingCompilationMismatch,
            .modules = value.modules orelse return error.CompilerBindingCompilationMismatch,
        };
        if (graph.compiles.len == 0 or graph.compiles.len > native.maximum_compiles or graph.modules.len == 0 or graph.modules.len > native.maximum_modules) return error.CompilerBindingCompilationMismatch;
        try sameCompiler(expected, graph.compiles[0].compile);
        var edges: [native.maximum_compiles][native.maximum_compiles]bool = @splat(@splat(false));
        var all_modules: [native.maximum_modules]bool = @splat(false);
        var references: usize = 0;
        for (graph.modules, 0..) |module, id| {
            if (module.id != id) return error.CompilerBindingCompilationMismatch;
            references += module.imports.len + module.link_objects.len;
            if (references > native.maximum_references) return error.CompilerBindingReferenceCountExceeded;
            for (module.imports) |item| {
                if (item.module) |target| {
                    if (item.derived != null or target >= graph.modules.len) return error.CompilerBindingCompilationMismatch;
                } else if (item.derived == null or !std.mem.eql(u8, item.derived.?, "compiled-input-manifest/v1")) return error.CompilerBindingCompilationMismatch;
            }
            for (module.link_objects) |object| {
                if (object.other_step) |child| if (child.compile >= graph.compiles.len) return error.CompilerBindingCompilationMismatch;
            }
        }
        for (graph.compiles, 0..) |node, id| {
            if (node.id != id or node.root_module >= graph.modules.len) return error.CompilerBindingCompilationMismatch;
            try compiler(node.compile);
            if (id == 0) {
                if (node.output != null) return error.CompilerBindingCompilationMismatch;
            } else {
                if (!std.mem.eql(u8, node.compile.kind, "obj")) return error.CompilerBindingCompilationMismatch;
                const output = node.output orelse return error.CompilerBindingCompilationMismatch;
                try path(output.path);
                var name_buffer: [96]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "compiles/{d}/output", .{id});
                if (!std.mem.eql(u8, name, output.file.input) or !std.mem.eql(u8, output.file.origin, "generated")) return error.CompilerBindingCompilationMismatch;
                var scoped_buffer: [128]u8 = undefined;
                const scoped = try std.fmt.bufPrint(&scoped_buffer, "compilations/0/{s}", .{name});
                const found = for (entries) |entry| {
                    if (std.mem.eql(u8, entry.path, scoped)) break entry;
                } else return error.CompilerBindingInputMissing;
                if (found.pinned_source.len != 0 or found.byte_length == 0) return error.CompilerBindingInputMismatch;
            }
            var queue: [native.maximum_modules]u32 = undefined;
            var seen: [native.maximum_modules]bool = @splat(false);
            queue[0] = node.root_module;
            seen[node.root_module] = true;
            var count: usize = 1;
            var cursor: usize = 0;
            while (cursor < count) : (cursor += 1) {
                const module_id = queue[cursor];
                all_modules[module_id] = true;
                const module = graph.modules[module_id];
                for (module.imports) |item| if (item.module) |target| {
                    if (seen[target]) continue;
                    seen[target] = true;
                    queue[count] = target;
                    count += 1;
                };
                for (module.link_objects) |object| if (object.other_step) |child| {
                    edges[id][child.compile] = true;
                };
            }
        }
        var colors: [native.maximum_compiles]u2 = @splat(0);
        const Frame = struct { node: usize, next: usize = 0 };
        var stack: [native.maximum_compiles]Frame = undefined;
        stack[0] = .{ .node = 0 };
        colors[0] = 1;
        var count: usize = 1;
        while (count != 0) {
            const frame = &stack[count - 1];
            if (frame.next == graph.compiles.len) {
                colors[frame.node] = 2;
                count -= 1;
                continue;
            }
            const child = frame.next;
            frame.next += 1;
            if (!edges[frame.node][child]) continue;
            if (colors[child] == 1) return error.CompilerBindingLinkedCycle;
            if (colors[child] == 2) continue;
            colors[child] = 1;
            stack[count] = .{ .node = child };
            count += 1;
        }
        for (colors[0..graph.compiles.len]) |color| if (color != 2) return error.CompilerBindingUnreachableCompile;
        for (all_modules[0..graph.modules.len]) |seen| if (!seen) return error.CompilerBindingUnreachableModule;
    } else return error.CompilerBindingCompilationMismatch;
}

fn sameCompiler(expected: Compiler, actual: Compiler) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or !std.mem.eql(u8, expected.kind, actual.kind)) return error.CompilerBindingCompilationMismatch;
}

fn matches(entries: []const native.Entry, name: []const u8, bytes: []const u8) !void {
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.path, name)) continue;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        if (entry.byte_length != bytes.len or !std.mem.eql(u8, &entry.sha256, &hash)) {
            return error.CompilerBindingInputMismatch;
        }
        return;
    }
    return error.CompilerBindingInputMissing;
}

pub const exposure_schema = "tiny.compiled-binding-exposure/v1";
/// The most exposures one graph registers. It is a capacity, not a census:
/// the count sizes only the locator set, `locatorSetBytesMax`, which the
/// exposure tests hold under 4 MiB. One exposure costs one run step at
/// configure time and one locator of at most `locatorBytesMax` bytes,
/// 17,216, so 243 would fit. 128 takes 2,203,648 bytes and equals the
/// tuples of two roles over every ordinal. Chic's complete graph registers
/// 68 at 42ec53f3c5. Past 112, derive the bound again before raising it.
pub const maximum_exposures = 128;
/// Keep the existing ordinal namespace independent of the number of roles.
pub const maximum_exposure_ordinals = maximum_bindings;
pub const maximum_role_bytes = 32;
pub const maximum_exposure_step_bytes = 128;

pub const Selection = struct {
    aggregate: enum { default, retained, host, profile, fixture },
    ordinal: u8,
    role: []const u8 = "primary",

    pub fn validate(self: Selection) !void {
        if (self.ordinal >= maximum_exposure_ordinals) return error.CompilerBindingOrdinalTooLarge;
        if (self.role.len == 0 or self.role.len > maximum_role_bytes) return error.CompilerBindingRoleTooLarge;
        for (self.role) |byte| {
            if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return error.InvalidCompilerBindingRole;
        }
    }
};

pub const Locator = struct {
    schema: []const u8 = exposure_schema,
    selection: Selection,
    source_record: Identity,
    record: Identity,
    exposure_step: []const u8,
};

/// Two absolute paths with at most two JSON bytes per admitted path byte,
/// escaped role/step strings and fixed schema, keys, hashes and integer framing.
pub fn locatorBytesMax() usize {
    return 4 * maximum_path_bytes + 2 * maximum_role_bytes + 2 * maximum_exposure_step_bytes + 512;
}

pub fn locatorSetBytesMax() usize {
    return maximum_exposures * locatorBytesMax();
}

pub const ExposureAnnouncement = struct {
    schema: []const u8 = "tiny.compiled-binding-exposure-receipt/v1",
    locator: Identity,
    generated_locator: []const u8,
    selection: Selection,
    exposure_step: []const u8,
};
