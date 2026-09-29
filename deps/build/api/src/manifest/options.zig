const std = @import("std");

/// References are encoded by the graph owner. Administrative fields describe
/// build execution or derived outputs; they cannot change the compiler program.
const Class = enum { value, reference, administrative, special };

const module_fields = .{
    .owner = Class.administrative,
    .root_source_file = Class.reference,
    .import_table = Class.reference,
    .resolved_target = Class.special,
    .optimize = Class.value,
    .dwarf_format = Class.value,
    .c_macros = Class.special,
    .include_dirs = Class.reference,
    .lib_paths = Class.reference,
    .rpaths = Class.reference,
    .frameworks = Class.reference,
    .link_objects = Class.reference,
    .strip = Class.value,
    .unwind_tables = Class.value,
    .single_threaded = Class.value,
    .stack_protector = Class.value,
    .stack_check = Class.value,
    .sanitize_c = Class.value,
    .sanitize_thread = Class.value,
    .fuzz = Class.value,
    .code_model = Class.value,
    .valgrind = Class.value,
    .pic = Class.value,
    .red_zone = Class.value,
    .omit_frame_pointer = Class.value,
    .error_tracing = Class.value,
    .link_libc = Class.value,
    .link_libcpp = Class.value,
    .no_builtin = Class.value,
    .export_symbol_names = Class.value,
    .cached_graph = Class.administrative,
};

const compile_fields = .{
    .step = Class.administrative,
    .root_module = Class.reference,
    .name = Class.value,
    .linker_script = Class.reference,
    .version_script = Class.reference,
    .out_filename = Class.administrative,
    .linkage = Class.value,
    .version = Class.value,
    .kind = Class.value,
    .formatted_panics = Class.value,
    .compress_debug_sections = Class.value,
    .verbose_link = Class.administrative,
    .verbose_cc = Class.administrative,
    .bundle_compiler_rt = Class.value,
    .bundle_ubsan_rt = Class.value,
    .rdynamic = Class.value,
    .import_memory = Class.value,
    .export_memory = Class.value,
    .import_symbols = Class.value,
    .import_table = Class.value,
    .export_table = Class.value,
    .initial_memory = Class.value,
    .max_memory = Class.value,
    .shared_memory = Class.value,
    .global_base = Class.value,
    .zig_lib_dir = Class.reference,
    .filters = Class.value,
    .test_runner = Class.reference,
    .wasi_exec_model = Class.value,
    .installed_headers = Class.reference,
    .installed_headers_include_tree = Class.administrative,
    .rc_includes = Class.value,
    .win32_manifest = Class.reference,
    .win32_module_definition = Class.reference,
    .image_base = Class.value,
    .libc_file = Class.reference,
    .each_lib_rpath = Class.value,
    .build_id = Class.special,
    .link_eh_frame_hdr = Class.value,
    .link_emit_relocs = Class.value,
    .link_function_sections = Class.value,
    .link_data_sections = Class.value,
    .link_gc_sections = Class.value,
    .linker_dynamicbase = Class.value,
    .linker_allow_shlib_undefined = Class.value,
    .linker_allow_undefined_version = Class.value,
    .linker_enable_new_dtags = Class.value,
    .link_z_notext = Class.value,
    .link_z_relro = Class.value,
    .link_z_lazy = Class.value,
    .link_z_common_page_size = Class.value,
    .link_z_max_page_size = Class.value,
    .link_z_defs = Class.value,
    .install_name = Class.value,
    .entitlements = Class.reference,
    .pagezero_size = Class.value,
    .headerpad_size = Class.value,
    .headerpad_max_install_names = Class.value,
    .dead_strip_dylibs = Class.value,
    .force_load_objc = Class.value,
    .discard_local_symbols = Class.value,
    .pie = Class.value,
    .lto = Class.value,
    .dll_export_fns = Class.value,
    .subsystem = Class.value,
    .mingw_unicode_entry_point = Class.value,
    .entry = Class.value,
    .force_undefined_symbols = Class.special,
    .stack_size = Class.value,
    .use_llvm = Class.value,
    .use_lld = Class.value,
    .use_new_linker = Class.value,
    .allow_so_scripts = Class.value,
    .expect_errors = Class.value,
    .error_limit = Class.value,
    .is_linking_libc = Class.administrative,
    .is_linking_libcpp = Class.administrative,
    .sanitize_coverage_trace_pc_guard = Class.value,
    .incremental = Class.administrative,
    .emit_directory = Class.administrative,
    .generated_docs = Class.administrative,
    .generated_asm = Class.administrative,
    .generated_bin = Class.administrative,
    .generated_pdb = Class.administrative,
    .generated_implib = Class.administrative,
    .generated_llvm_bc = Class.administrative,
    .generated_llvm_ir = Class.administrative,
    .generated_h = Class.administrative,
};

pub fn classify(comptime T: type, comptime fields: anytype) void {
    const actual = @typeInfo(T).@"struct".field_names;
    const declared = @typeInfo(@TypeOf(fields)).@"struct".field_names;
    if (actual.len != declared.len) @compileError("classify every compiler input field");
    inline for (actual, declared) |field, expected| {
        if (!std.mem.eql(u8, field, expected)) {
            @compileError("update the explicit compiler input classification");
        }
    }
}

pub fn moduleValues(json: *std.json.Stringify, value: *const std.Build.Module) !void {
    comptime classify(std.Build.Module, module_fields);
    inline for (@typeInfo(std.Build.Module).@"struct".field_names) |field| {
        if (@field(module_fields, field) == .value) {
            try json.objectField(field);
            try json.write(@field(value, field));
        }
    }
    try json.objectField("c_macros");
    try json.write(value.c_macros.items);
    try json.objectField("resolved_target");
    if (value.resolved_target) |resolved| {
        comptime classify(std.Build.ResolvedTarget, .{ .query = {}, .result = {} });
        try json.beginObject();
        try json.objectField("query");
        try query(json, resolved.query);
        try json.objectField("result");
        try target(json, resolved.result);
        try json.endObject();
    } else try json.write(null);
}

pub fn compileValues(json: *std.json.Stringify, value: *const std.Build.Step.Compile) !void {
    comptime classify(std.Build.Step.Compile, compile_fields);
    inline for (@typeInfo(std.Build.Step.Compile).@"struct".field_names) |field| {
        if (@field(compile_fields, field) == .value) {
            try json.objectField(field);
            try json.write(@field(value, field));
        }
    }
    try json.objectField("build_id");
    if (value.build_id) |id| {
        try json.beginObject();
        try json.objectField(@tagName(id));
        switch (id) {
            .hexstring => |*hex| try json.write(hex.toSlice()),
            else => try json.write(null),
        }
        try json.endObject();
    } else try json.write(null);
    try json.objectField("force_undefined_symbols");
    try json.write(value.force_undefined_symbols.keys());
}

/// The dynamic-linker buffer tail is uninitialized storage, not an input.
/// CPU pointers are expanded to their values; no address enters the record.
pub fn target(json: *std.json.Stringify, value: std.Target) !void {
    comptime classify(std.Target, .{
        .cpu = {},
        .os = {},
        .abi = {},
        .ofmt = {},
        .dynamic_linker = {},
    });
    comptime classify(std.Target.Cpu, .{ .arch = {}, .model = {}, .features = {} });
    comptime classify(std.Target.Cpu.Model, .{ .name = {}, .llvm_name = {}, .features = {} });
    comptime classify(std.Target.DynamicLinker, .{ .buffer = {}, .len = {} });
    comptime classify(std.Target.Os, .{ .tag = {}, .version_range = {} });
    try json.write(.{
        .cpu = .{
            .arch = value.cpu.arch,
            .model = value.cpu.model.*,
            .features = value.cpu.features,
        },
        .os = .{ .tag = value.os.tag, .version_range = value.os.versionRange() },
        .abi = value.abi,
        .ofmt = value.ofmt,
        .dynamic_linker = value.dynamic_linker.get(),
    });
}

fn query(json: *std.json.Stringify, value: std.Target.Query) !void {
    const fields = .{
        .cpu_arch = {},
        .cpu_model = {},
        .cpu_features_add = {},
        .cpu_features_sub = {},
        .os_tag = {},
        .os_version_min = {},
        .os_version_max = {},
        .glibc_version = {},
        .android_api_level = {},
        .abi = {},
        .dynamic_linker = {},
        .ofmt = {},
    };
    comptime classify(std.Target.Query, fields);
    try json.beginObject();
    inline for (@typeInfo(std.Target.Query).@"struct".field_names) |field| {
        try json.objectField(field);
        if (comptime std.mem.eql(u8, field, "dynamic_linker")) {
            try json.write(if (value.dynamic_linker) |linker| linker.get() else null);
        } else try json.write(@field(value, field));
    }
    try json.endObject();
}
