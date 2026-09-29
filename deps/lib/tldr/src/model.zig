const std = @import("std");

pub const ObjectFormat = enum {
    elf,
    coff,
    macho,
    wasm,
};

pub const Architecture = enum {
    unknown,
    x86_64,
    aarch64,
    riscv64,
    wasm32,
};

pub const Endianness = enum {
    little,
    big,
};

pub const OutputKind = enum {
    executable,
    relocatable,
    shared_library,
};

pub const IncrementalMode = enum {
    off,
    prepare,
    relink,
};

pub const IcfMode = enum {
    off,
    all,
};

pub const BuildIdMode = enum {
    none,
    fast,
    sha1,
};

pub const ProductStage = enum {
    input_discovery,
    archive_member_selection,
    archive_table_parse,
    archive_definition_indexing,
    archive_summary_parse,
    archive_symbol_recording,
    selected_member_parse,
    symbol_database,
    section_contribution_graph,
    contribution_ehframe_scan,
    contribution_classification,
    contribution_merge_registration,
    contribution_chain_assignment,
    contribution_string_merge,
    duplicate_policy,
    layout_groups,
    address_assignment,
    relaxation,
    relocation_application,
    output_writing,
    write_symbol_table,
    write_zero_fill,
    payload_materialization,
    write_metadata,
    relink_manifest_decode,
    relink_change_detection,
    relink_direct_evidence,
    relink_output_io,
    relink_patch_apply,
    diagnostics,
    manifest_recording,

    pub fn label(self: ProductStage) []const u8 {
        return switch (self) {
            .input_discovery => "input discovery",
            .archive_member_selection => "archive member selection",
            .archive_table_parse => "archive table parse",
            .archive_definition_indexing => "archive definition indexing",
            .archive_summary_parse => "archive summary parse",
            .archive_symbol_recording => "archive symbol recording",
            .selected_member_parse => "selected member parse",
            .symbol_database => "symbol database",
            .section_contribution_graph => "section contribution graph",
            .contribution_ehframe_scan => "contribution eh_frame scan",
            .contribution_classification => "contribution classification",
            .contribution_merge_registration => "contribution merge registration",
            .contribution_chain_assignment => "contribution chain assignment",
            .contribution_string_merge => "contribution string merge",
            .duplicate_policy => "duplicate policy",
            .layout_groups => "layout groups",
            .address_assignment => "address assignment",
            .relaxation => "relaxation",
            .relocation_application => "relocation application",
            .output_writing => "output writing",
            .write_symbol_table => "write symbol table",
            .write_zero_fill => "write zero fill",
            .payload_materialization => "payload materialization",
            .write_metadata => "write metadata",
            .relink_manifest_decode => "relink manifest decode",
            .relink_change_detection => "relink change detection",
            .relink_direct_evidence => "relink direct evidence",
            .relink_output_io => "relink output io",
            .relink_patch_apply => "relink patch apply",
            .diagnostics => "diagnostics",
            .manifest_recording => "manifest recording",
        };
    }

    pub fn traceName(comptime self: ProductStage) []const u8 {
        return switch (self) {
            .input_discovery => "parse",
            .archive_member_selection => "archive",
            .archive_table_parse => "table",
            .archive_definition_indexing => "indexing",
            .archive_summary_parse => "summary",
            .archive_symbol_recording => "recording",
            .selected_member_parse => "selected",
            .symbol_database => "symbol",
            .section_contribution_graph => "contribution",
            .contribution_ehframe_scan => "ehscan",
            .contribution_classification => "classify",
            .contribution_merge_registration => "register",
            .contribution_chain_assignment => "chains",
            .contribution_string_merge => "strings",
            .duplicate_policy => "duplicate",
            .layout_groups => "layout",
            .address_assignment => "address",
            .relaxation => "relaxation",
            .relocation_application => "relocation",
            .output_writing => "write",
            .write_symbol_table => "symtab",
            .write_zero_fill => "zerofill",
            .payload_materialization => "materialize",
            .write_metadata => "metadata",
            .relink_manifest_decode => "manifest",
            .relink_change_detection => "changes",
            .relink_direct_evidence => "evidence",
            .relink_output_io => "outputio",
            .relink_patch_apply => "patch",
            .diagnostics => "diagnostics",
            .manifest_recording => "manifest",
        };
    }
};

pub const product_stage_order = [_]ProductStage{
    .input_discovery,
    .archive_member_selection,
    .archive_table_parse,
    .archive_definition_indexing,
    .archive_summary_parse,
    .archive_symbol_recording,
    .selected_member_parse,
    .symbol_database,
    .section_contribution_graph,
    .contribution_ehframe_scan,
    .contribution_classification,
    .contribution_merge_registration,
    .contribution_chain_assignment,
    .contribution_string_merge,
    .duplicate_policy,
    .layout_groups,
    .address_assignment,
    .relaxation,
    .relocation_application,
    .output_writing,
    .write_symbol_table,
    .write_zero_fill,
    .payload_materialization,
    .write_metadata,
    .relink_manifest_decode,
    .relink_change_detection,
    .relink_direct_evidence,
    .relink_output_io,
    .relink_patch_apply,
    .diagnostics,
    .manifest_recording,
};

pub const Target = struct {
    object_format: ObjectFormat = .elf,
    architecture: Architecture = .x86_64,
    endianness: Endianness = .little,
    pointer_width_bits: u16 = 64,

    pub const linux_x86_64_elf: Target = .{
        .object_format = .elf,
        .architecture = .x86_64,
        .endianness = .little,
        .pointer_width_bits = 64,
    };

    pub const windows_x86_64_coff: Target = .{
        .object_format = .coff,
        .architecture = .x86_64,
        .endianness = .little,
        .pointer_width_bits = 64,
    };

    pub const macos_x86_64_macho: Target = .{
        .object_format = .macho,
        .architecture = .x86_64,
        .endianness = .little,
        .pointer_width_bits = 64,
    };
};

pub const LinkCommitObserver = struct {
    context: *anyopaque,
    committed: *const fn (context: *anyopaque) void,

    pub fn notify(self: LinkCommitObserver) void {
        self.committed(self.context);
    }
};

pub const LinkOptions = struct {
    target: Target = .linux_x86_64_elf,
    output_kind: OutputKind = .executable,
    entry_symbol: []const u8 = "_start",
    image_base: u64 = 0x400000,
    page_size: u64 = 0x1000,
    pie: bool = false,
    dynamic_linker: ?[]const u8 = null,
    soname: ?[]const u8 = null,
    export_dynamic: bool = false,
    eh_frame_header: bool = false,
    incremental_mode: IncrementalMode = .prepare,
    incremental_reserve_percent: u8 = 24,
    inputs_read_at_ns: i64 = 0,
    gc_sections: bool = false,
    icf: IcfMode = .off,
    strip_debug: bool = false,
    build_id: BuildIdMode = .none,
    max_link_jobs: usize = 0,
    mapped_output_file: ?std.Io.File = null,
    mapped_output_min_size: usize = 8 * 1024 * 1024,
    diagnostics: ?*Diagnostics = null,
    commit_observer: ?LinkCommitObserver = null,

    pub fn requiresDynamicLinking(self: LinkOptions) bool {
        return self.output_kind == .shared_library or
            self.pie or
            self.dynamic_linker != null or
            self.soname != null or
            self.export_dynamic;
    }
};

pub const InputIdentity = struct {
    mtime_ns: i64,
    inode: u64,
};

pub const Input = struct {
    name: []const u8,
    bytes: []const u8,
    identity: ?InputIdentity = null,
};

pub const Diagnostics = struct {
    pub const max_recorded_undefined_symbols = 8;

    first_undefined_symbol: ?UndefinedSymbol = null,
    first_unsupported_relocation: ?UnsupportedRelocation = null,
    first_unsupported_input_format: ?UnsupportedInputFormat = null,
    undefined_symbols: [max_recorded_undefined_symbols]UndefinedSymbol = undefined,
    undefined_symbol_count: usize = 0,

    pub const UndefinedSymbol = struct {
        name: []const u8,
        input_name: []const u8,
    };

    pub const UnsupportedRelocation = struct {
        input_name: []const u8,
        section_name: []const u8,
        symbol_name: []const u8,
        relocation_type: u32,
    };

    pub const UnsupportedInputFormat = struct {
        input_name: []const u8,
        member_name: ?[]const u8 = null,
        input_format: ObjectFormat,
        target_format: ObjectFormat,
    };

    pub const UndefinedSymbols = struct {
        symbols: []const UndefinedSymbol,
        hidden_count: usize = 0,
    };

    pub const LinkFailure = union(enum) {
        undefined_symbols: UndefinedSymbols,
        undefined_symbol: UndefinedSymbol,
        unsupported_relocation: UnsupportedRelocation,
        unsupported_input_format: UnsupportedInputFormat,
        generic: Error,
    };

    pub fn clear(self: *Diagnostics) void {
        self.* = .{};
    }

    pub fn recordUndefinedSymbol(
        self: *Diagnostics,
        input_name: []const u8,
        symbol_name: []const u8,
    ) void {
        if (self.undefined_symbol_count < self.undefined_symbols.len) {
            self.undefined_symbols[self.undefined_symbol_count] = .{
                .name = symbol_name,
                .input_name = input_name,
            };
        }
        self.undefined_symbol_count += 1;
        if (self.first_undefined_symbol == null) {
            self.first_undefined_symbol = .{
                .name = symbol_name,
                .input_name = input_name,
            };
        }
    }

    pub fn recordedUndefinedSymbols(self: *const Diagnostics) []const UndefinedSymbol {
        return self.undefined_symbols[0..@min(self.undefined_symbol_count, self.undefined_symbols.len)];
    }

    pub fn recordUnsupportedRelocation(
        self: *Diagnostics,
        input_name: []const u8,
        section_name: []const u8,
        symbol_name: []const u8,
        relocation_type: u32,
    ) void {
        if (self.first_unsupported_relocation == null) {
            self.first_unsupported_relocation = .{
                .input_name = input_name,
                .section_name = section_name,
                .symbol_name = symbol_name,
                .relocation_type = relocation_type,
            };
        }
    }

    pub fn recordUnsupportedInputFormat(
        self: *Diagnostics,
        input_name: []const u8,
        input_format: ObjectFormat,
        target_format: ObjectFormat,
    ) void {
        if (self.first_unsupported_input_format == null) {
            self.first_unsupported_input_format = .{
                .input_name = input_name,
                .input_format = input_format,
                .target_format = target_format,
            };
        }
    }

    pub fn recordUnsupportedArchiveMemberFormat(
        self: *Diagnostics,
        input_name: []const u8,
        member_name: []const u8,
        input_format: ObjectFormat,
        target_format: ObjectFormat,
    ) void {
        if (self.first_unsupported_input_format == null) {
            self.first_unsupported_input_format = .{
                .input_name = input_name,
                .member_name = member_name,
                .input_format = input_format,
                .target_format = target_format,
            };
        }
    }

    pub fn linkFailure(self: *const Diagnostics, err: Error) LinkFailure {
        if (err == error.UndefinedSymbol) {
            const undefined_symbols = self.recordedUndefinedSymbols();
            if (undefined_symbols.len > 1) {
                return .{ .undefined_symbols = .{
                    .symbols = undefined_symbols,
                    .hidden_count = self.undefined_symbol_count - undefined_symbols.len,
                } };
            }
            if (self.first_undefined_symbol) |undefined_symbol| {
                return .{ .undefined_symbol = undefined_symbol };
            }
        }

        if (err == error.UnsupportedRelocation) {
            if (self.first_unsupported_relocation) |relocation| {
                return .{ .unsupported_relocation = relocation };
            }
        }

        if (err == error.UnsupportedFormat) {
            if (self.first_unsupported_input_format) |unsupported| {
                return .{ .unsupported_input_format = unsupported };
            }
        }

        return .{ .generic = err };
    }
};

pub const Error = std.mem.Allocator.Error || error{
    DuplicateSymbol,
    InvalidAlignment,
    InvalidArchive,
    InvalidElfHeader,
    InvalidObject,
    InvalidRange,
    InvalidStringTable,
    MissingEntrySymbol,
    MissingSection,
    MissingStringTable,
    MissingSymbolTable,
    NoAllocSections,
    RelocationOverflow,
    OutputFileError,
    SectionLayoutOverflow,
    TooManyProgramHeaders,
    TooManySections,
    UndefinedSymbol,
    UnsupportedArchitecture,
    UnsupportedDynamicLinking,
    UnsupportedEhFrameHeader,
    UnsupportedFormat,
    UnsupportedOutputKind,
    UnsupportedRelocation,
};

pub fn validateOptions(options: LinkOptions) Error!void {
    if (options.page_size == 0 or !std.math.isPowerOfTwo(options.page_size)) {
        return error.InvalidAlignment;
    }
    if (options.image_base % options.page_size != 0) {
        return error.InvalidAlignment;
    }
    if (options.target.pointer_width_bits != 64) return error.UnsupportedArchitecture;
}

test "diagnostics report multiple undefined symbols" {
    var diagnostics: Diagnostics = .{};
    diagnostics.recordUndefinedSymbol("tiny.o", "__tiny_make_integer");
    diagnostics.recordUndefinedSymbol("libtinyrt.a", "memcpy");

    const failure = diagnostics.linkFailure(error.UndefinedSymbol);
    const undefined_symbols = switch (failure) {
        .undefined_symbols => |undefined_symbols| undefined_symbols,
        else => return error.ExpectedUndefinedSymbolsDiagnostic,
    };
    try std.testing.expectEqual(@as(usize, 2), undefined_symbols.symbols.len);
    try std.testing.expectEqual(@as(usize, 0), undefined_symbols.hidden_count);
    try std.testing.expectEqualStrings("__tiny_make_integer", undefined_symbols.symbols[0].name);
    try std.testing.expectEqualStrings("tiny.o", undefined_symbols.symbols[0].input_name);
    try std.testing.expectEqualStrings("memcpy", undefined_symbols.symbols[1].name);
    try std.testing.expectEqualStrings("libtinyrt.a", undefined_symbols.symbols[1].input_name);
}

test "product stages define shared labels and trace names" {
    try std.testing.expectEqual(@as(usize, 31), product_stage_order.len);
    try std.testing.expectEqual(ProductStage.input_discovery, product_stage_order[0]);
    try std.testing.expectEqual(ProductStage.manifest_recording, product_stage_order[product_stage_order.len - 1]);
    try std.testing.expectEqualStrings("section contribution graph", ProductStage.section_contribution_graph.label());
    try std.testing.expectEqualStrings("contribution", ProductStage.section_contribution_graph.traceName());
    try std.testing.expectEqualStrings("contribution string merge", ProductStage.contribution_string_merge.label());
    try std.testing.expectEqualStrings("chains", ProductStage.contribution_chain_assignment.traceName());
    try std.testing.expectEqualStrings("manifest", ProductStage.manifest_recording.traceName());
    try std.testing.expectEqualStrings("archive summary parse", ProductStage.archive_summary_parse.label());
    try std.testing.expectEqualStrings("recording", ProductStage.archive_symbol_recording.traceName());
    try std.testing.expectEqualStrings("selected", ProductStage.selected_member_parse.traceName());
}

test "diagnostics report unsupported relocation details" {
    var diagnostics: Diagnostics = .{};
    diagnostics.recordUnsupportedRelocation("tiny.o", ".text", "__tiny_runtime_call", 42);

    const failure = diagnostics.linkFailure(error.UnsupportedRelocation);
    const relocation = switch (failure) {
        .unsupported_relocation => |relocation| relocation,
        else => return error.ExpectedUnsupportedRelocationDiagnostic,
    };
    try std.testing.expectEqual(@as(u32, 42), relocation.relocation_type);
    try std.testing.expectEqualStrings("tiny.o", relocation.input_name);
    try std.testing.expectEqualStrings(".text", relocation.section_name);
    try std.testing.expectEqualStrings("__tiny_runtime_call", relocation.symbol_name);
}

test "diagnostics report unsupported input format details" {
    var diagnostics: Diagnostics = .{};
    diagnostics.recordUnsupportedInputFormat("main.obj", .coff, .elf);

    const failure = diagnostics.linkFailure(error.UnsupportedFormat);
    const unsupported = switch (failure) {
        .unsupported_input_format => |unsupported| unsupported,
        else => return error.ExpectedUnsupportedInputFormatDiagnostic,
    };
    try std.testing.expectEqual(ObjectFormat.coff, unsupported.input_format);
    try std.testing.expectEqual(ObjectFormat.elf, unsupported.target_format);
    try std.testing.expectEqualStrings("main.obj", unsupported.input_name);
}

test "diagnostics report unsupported archive member format details" {
    var diagnostics: Diagnostics = .{};
    diagnostics.recordUnsupportedArchiveMemberFormat("libmixed.a", "needed.obj", .coff, .elf);

    const failure = diagnostics.linkFailure(error.UnsupportedFormat);
    const unsupported = switch (failure) {
        .unsupported_input_format => |unsupported| unsupported,
        else => return error.ExpectedUnsupportedInputFormatDiagnostic,
    };
    try std.testing.expectEqual(ObjectFormat.coff, unsupported.input_format);
    try std.testing.expectEqual(ObjectFormat.elf, unsupported.target_format);
    try std.testing.expectEqualStrings("libmixed.a", unsupported.input_name);
    try std.testing.expectEqualStrings("needed.obj", unsupported.member_name orelse return error.ExpectedUnsupportedInputFormatDiagnostic);
}
