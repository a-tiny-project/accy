const std = @import("std");

pub const NoLibcArtifactPolicy = union(enum) {
    none,
    all,
    artifacts: []const *std.Build.Step.Compile,
};

pub const NoLibcNeededCheck = struct {
    target: std.Build.ResolvedTarget,
    step_name: []const u8,
    description: []const u8,
    label: []const u8,
    artifacts: []const *std.Build.Step.Compile,
    strict_undefined: NoLibcArtifactPolicy = .none,
    forbidden_definitions: NoLibcArtifactPolicy = .none,
    foreign_allocations: NoLibcArtifactPolicy = .none,
    forbid_foreign_objects: bool = false,
};
pub fn addNoLibcNeededCheck(b: *std.Build, options: NoLibcNeededCheck) ?*std.Build.Step {
    if (options.target.result.os.tag != .linux) return null;

    const run = b.addSystemCommand(&.{
        "bash",
        "-c",
        noLibcNeededScript(b, options),
        options.label,
    });
    for (options.artifacts) |artifact| {
        run.addArtifactArg(artifact);
    }

    const step = b.step(options.step_name, options.description);
    step.dependOn(&run.step);
    var assembly_check_needed = false;
    for (options.artifacts) |artifact| {
        inline for (.{ "c", "m" }) |library| {
            if (hasSystemLibraryDependency(b.allocator, artifact, library)) {
                const failure = b.addFail(b.fmt(
                    "[{s}] {s} transitively depends on lib{s}",
                    .{ options.label, artifact.out_filename, library },
                ));
                step.dependOn(&failure.step);
            }
        }
        if (options.forbid_foreign_objects) {
            assembly_check_needed = true;
            const foreign_object = foreignObjectDependency(
                b.allocator,
                artifact,
            ) orelse continue;
            const failure = b.addFail(b.fmt(
                "[{s}] {s} transitively includes foreign object code ({s})",
                .{
                    options.label,
                    artifact.out_filename,
                    @tagName(foreign_object),
                },
            ));
            step.dependOn(&failure.step);
        }
    }
    if (assembly_check_needed) {
        addAssemblyMemorySeamCheck(
            b,
            step,
            options.label,
            options.artifacts,
        );
    }
    return step;
}

fn hasSystemLibraryDependency(
    allocator: std.mem.Allocator,
    artifact: *std.Build.Step.Compile,
    name: []const u8,
) bool {
    var compiles: std.AutoArrayHashMapUnmanaged(*std.Build.Step.Compile, void) = .empty;
    defer compiles.deinit(allocator);
    var modules: std.AutoArrayHashMapUnmanaged(*std.Build.Module, void) = .empty;
    defer modules.deinit(allocator);

    compiles.put(allocator, artifact, {}) catch @panic("OOM");
    var compile_index: usize = 0;
    var module_index: usize = 0;
    var links_libc = false;
    var links_libcpp = false;

    while (compile_index < compiles.count() or module_index < modules.count()) {
        while (compile_index < compiles.count()) : (compile_index += 1) {
            const compile = compiles.keys()[compile_index];
            modules.put(allocator, compile.root_module, {}) catch @panic("OOM");
        }
        while (module_index < modules.count()) : (module_index += 1) {
            const module = modules.keys()[module_index];
            links_libc = links_libc or (module.link_libc orelse false);
            links_libcpp = links_libcpp or (module.link_libcpp orelse false);
            for (module.import_table.values()) |import| {
                modules.put(allocator, import, {}) catch @panic("OOM");
            }
            for (module.link_objects.items) |object| switch (object) {
                .system_lib => |library| {
                    if (std.mem.eql(u8, library.name, name)) return true;
                },
                .other_step => |compile| {
                    compiles.put(allocator, compile, {}) catch @panic("OOM");
                },
                else => {},
            };
        }
    }

    const target = artifact.rootModuleTarget();
    if (std.zig.target.isLibCLibName(&target, name)) return links_libc;
    if (std.zig.target.isLibCxxLibName(&target, name)) return links_libcpp;
    return false;
}

const ForeignObjectKind = enum {
    static_path,
    system_library,
    c_source,
    win32_resource,
};

fn foreignObjectDependency(
    allocator: std.mem.Allocator,
    artifact: *std.Build.Step.Compile,
) ?ForeignObjectKind {
    var compiles: std.AutoArrayHashMapUnmanaged(*std.Build.Step.Compile, void) = .empty;
    defer compiles.deinit(allocator);
    var modules: std.AutoArrayHashMapUnmanaged(*std.Build.Module, void) = .empty;
    defer modules.deinit(allocator);

    compiles.put(allocator, artifact, {}) catch @panic("OOM");
    var compile_index: usize = 0;
    var module_index: usize = 0;
    while (compile_index < compiles.count() or module_index < modules.count()) {
        while (compile_index < compiles.count()) : (compile_index += 1) {
            const compile = compiles.keys()[compile_index];
            modules.put(allocator, compile.root_module, {}) catch @panic("OOM");
        }
        while (module_index < modules.count()) : (module_index += 1) {
            const module = modules.keys()[module_index];
            for (module.import_table.values()) |import| {
                modules.put(allocator, import, {}) catch @panic("OOM");
            }
            for (module.link_objects.items) |object| switch (object) {
                .other_step => |compile| {
                    compiles.put(allocator, compile, {}) catch @panic("OOM");
                },
                .static_path => return .static_path,
                .system_lib => return .system_library,
                .assembly_file => {},
                .c_source_file, .c_source_files => return .c_source,
                .win32_resource_file => return .win32_resource,
            };
        }
    }
    return null;
}

fn addAssemblyMemorySeamCheck(
    b: *std.Build,
    step: *std.Build.Step,
    label: []const u8,
    artifacts: []const *std.Build.Step.Compile,
) void {
    const run = b.addSystemCommand(&.{
        "bash",
        "-c",
        assembly_memory_seam_script,
        label,
    });
    var compiles: std.AutoArrayHashMapUnmanaged(
        *std.Build.Step.Compile,
        void,
    ) = .empty;
    var modules: std.AutoArrayHashMapUnmanaged(
        *std.Build.Module,
        void,
    ) = .empty;
    for (artifacts) |artifact| {
        compiles.put(b.graph.arena, artifact, {}) catch @panic("OOM");
    }
    var compile_index: usize = 0;
    var module_index: usize = 0;
    while (compile_index < compiles.count() or module_index < modules.count()) {
        while (compile_index < compiles.count()) : (compile_index += 1) {
            const compile = compiles.keys()[compile_index];
            modules.put(
                b.graph.arena,
                compile.root_module,
                {},
            ) catch @panic("OOM");
        }
        while (module_index < modules.count()) : (module_index += 1) {
            const module = modules.keys()[module_index];
            for (module.import_table.values()) |import| {
                modules.put(b.graph.arena, import, {}) catch @panic("OOM");
            }
            for (module.link_objects.items) |object| switch (object) {
                .other_step => |compile| {
                    compiles.put(
                        b.graph.arena,
                        compile,
                        {},
                    ) catch @panic("OOM");
                },
                .assembly_file => |source| run.addFileArg(source),
                else => {},
            };
        }
    }
    step.dependOn(&run.step);
}

const assembly_memory_seam_script =
    \\set -euo pipefail
    \\status=0
    \\for source in "$@"; do
    \\  matches="$(grep -Ein '(^|[[:space:]:])(syscall|sysenter|svc)([[:space:]]|$)|(^|[[:space:]:])int[[:space:]]+[$]?(0x80|128)([[:space:]]|$)' "$source" || true)"
    \\  if [ -n "$matches" ]; then
    \\    echo "[$0] $source contains direct operating-system transitions:" >&2
    \\    echo "$matches" >&2
    \\    status=1
    \\  fi
    \\done
    \\exit "$status"
;

fn noLibcNeededScript(b: *std.Build, options: NoLibcNeededCheck) []const u8 {
    var script: std.ArrayList(u8) = .empty;
    const allocator = b.allocator;

    append(&script, allocator, "set -euo pipefail\n");
    append(&script, allocator, "if ! command -v readelf >/dev/null 2>&1; then\n");
    appendFmt(&script, allocator, "  echo \"[{s}] readelf is required\" >&2\n", .{options.label});
    append(&script, allocator, "  exit 1\n");
    append(&script, allocator, "fi\n");
    append(&script, allocator, "status=0\n");
    append(&script, allocator, "forbidden_symbol_re=\"^(__libc_.*|__errno_location|__errno|___errno|__error|_errno|_errnop|errno|getauxval|malloc|free|calloc|realloc|aligned_alloc|posix_memalign|dlopen|dlsym|dlclose|dlerror|clock_gettime|nanosleep|getrandom|mmap|munmap|mprotect|madvise|close|read|write|pipe|pipe2|fcntl|socket|socketpair|connect|bind|listen|accept|accept4|send|sendto|sendmsg|recv|recvfrom|recvmsg|setsockopt|getsockname|shutdown|poll|getpid|getppid|gettid|getuid|getgid|geteuid|getegid|kill|raise|sigaction|sigaltstack|sigprocmask|timer_create|timer_settime|timer_delete|exp|log|pow|sin|cos)$|^pthread_\"\n");
    append(&script, allocator, "foreign_allocation_symbol_re=\"^(malloc|free|calloc|realloc|reallocarray|aligned_alloc|posix_memalign|memalign|valloc|pvalloc|malloc_usable_size|mi_malloc|mi_zalloc|mi_calloc|mi_realloc|mi_free|je_malloc|je_calloc|je_realloc|je_free|rpmalloc|rpcalloc|rprealloc|rpfree|tc_malloc|tc_calloc|tc_realloc|tc_free|scalable_malloc|scalable_calloc|scalable_realloc|scalable_free|HeapAlloc|HeapReAlloc|HeapFree)$\"\n");
    appendArtifactSelectionFunction(&script, allocator, "strict_undefined_artifact", options.strict_undefined);
    appendArtifactSelectionFunction(&script, allocator, "forbidden_definitions_artifact", options.forbidden_definitions);
    appendArtifactSelectionFunction(&script, allocator, "foreign_allocations_artifact", options.foreign_allocations);
    append(&script, allocator, "for binary in \"$@\"; do\n");
    append(&script, allocator, "  matches=\"$(readelf -d \"$binary\" 2>/dev/null | awk -F'[][]' '/NEEDED/ { print $2 }' | grep -E '^(libc\\.so|libm\\.so|libmvec\\.so|ld-linux)' || true)\"\n");
    append(&script, allocator, "  if [ -n \"$matches\" ]; then\n");
    appendFmt(&script, allocator, "    echo \"[{s}] $binary links forbidden C runtime libraries:\" >&2\n", .{options.label});
    append(&script, allocator, "    echo \"$matches\" >&2\n");
    append(&script, allocator, "    status=1\n");
    append(&script, allocator, "  fi\n");
    append(&script, allocator, "  if strict_undefined_artifact \"$binary\"; then\n");
    append(&script, allocator, "    undefined=\"$(readelf -Ws \"$binary\" 2>/dev/null | awk '$7 == \"UND\" { print $8 }' | sed 's/@.*//' | grep -E \"$forbidden_symbol_re\" || true)\"\n");
    append(&script, allocator, "    if [ -n \"$undefined\" ]; then\n");
    appendFmt(&script, allocator, "      echo \"[{s}] $binary exposes forbidden unresolved C runtime symbols:\" >&2\n", .{options.label});
    append(&script, allocator, "      echo \"$undefined\" >&2\n");
    append(&script, allocator, "      status=1\n");
    append(&script, allocator, "    fi\n");
    append(&script, allocator, "  fi\n");
    append(&script, allocator, "  if forbidden_definitions_artifact \"$binary\"; then\n");
    append(&script, allocator, "    defined=\"$(readelf -Ws \"$binary\" 2>/dev/null | awk '$7 != \"UND\" && $5 != \"LOCAL\" { print $8 }' | sed 's/@.*//' | grep -E \"$forbidden_symbol_re\" || true)\"\n");
    append(&script, allocator, "    if [ -n \"$defined\" ]; then\n");
    appendFmt(&script, allocator, "      echo \"[{s}] $binary defines forbidden C runtime symbols:\" >&2\n", .{options.label});
    append(&script, allocator, "      echo \"$defined\" >&2\n");
    append(&script, allocator, "      status=1\n");
    append(&script, allocator, "    fi\n");
    append(&script, allocator, "  fi\n");
    append(&script, allocator, "  if foreign_allocations_artifact \"$binary\"; then\n");
    append(&script, allocator, "    foreign_allocations=\"$(readelf -Ws \"$binary\" 2>/dev/null | awk '{ print $8 }' | sed 's/@.*//' | grep -E \"$foreign_allocation_symbol_re\" | sort -u || true)\"\n");
    append(&script, allocator, "    if [ -n \"$foreign_allocations\" ]; then\n");
    appendFmt(&script, allocator, "      echo \"[{s}] $binary contains foreign allocation API symbols:\" >&2\n", .{options.label});
    append(&script, allocator, "      echo \"$foreign_allocations\" >&2\n");
    append(&script, allocator, "      status=1\n");
    append(&script, allocator, "    fi\n");
    append(&script, allocator, "  fi\n");
    append(&script, allocator, "done\n");
    append(&script, allocator, "exit \"$status\"\n");

    return script.toOwnedSlice(allocator) catch @panic("OOM");
}

fn appendArtifactSelectionFunction(
    script: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    policy: NoLibcArtifactPolicy,
) void {
    appendFmt(script, allocator, "{s}() {{\n", .{name});
    switch (policy) {
        .none => append(script, allocator, "  return 1\n"),
        .all => append(script, allocator, "  return 0\n"),
        .artifacts => |artifacts| {
            if (artifacts.len == 0) {
                append(script, allocator, "  return 1\n");
            } else {
                append(script, allocator, "  case \"$(basename \"$1\")\" in\n");
                append(script, allocator, "    ");
                for (artifacts, 0..) |artifact, index| {
                    if (index > 0) append(script, allocator, "|\\\n");
                    append(script, allocator, artifact.out_filename);
                }
                append(script, allocator, ")\n");
                append(script, allocator, "      return 0\n");
                append(script, allocator, "      ;;\n");
                append(script, allocator, "    *)\n");
                append(script, allocator, "      return 1\n");
                append(script, allocator, "      ;;\n");
                append(script, allocator, "  esac\n");
            }
        },
    }
    append(script, allocator, "}\n");
}

fn append(script: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) void {
    script.appendSlice(allocator, bytes) catch @panic("OOM");
}

fn appendFmt(
    script: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) void {
    append(script, allocator, std.fmt.allocPrint(allocator, fmt, args) catch @panic("OOM"));
}
