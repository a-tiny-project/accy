const std = @import("std");
const builtin = @import("builtin");
const pretty = @import("pretty");
const pretty_usage = @import("pretty_usage");
const sys = @import("sys");
const tldr = @import("tldr");

const Allocator = std.mem.Allocator;
const elf_object = tldr.formats.elf.object;

test "tldr cli package namespace" {
    std.testing.refAllDecls(@This());
}

const max_response_bytes = 16 * 1024 * 1024;
const max_object_bytes = 512 * 1024 * 1024;
const prefault_input_threshold = 64 * 1024 * 1024;

const usage_text =
    \\usage: tldr-link [-o PATH] [-e SYMBOL] [-L PATH] [-l LIB] [-pie] [-dynamic-linker PATH] [--eh-frame-hdr] [--build-id[=fast|sha1]] [--hash-style=gnu] [--gc-sections] [--strip-debug] [--icf=all|off] [--incremental=off|prepare|relink] [--incremental-manifest PATH] [--emit-link-map PATH] [-Map PATH] [--emit-manifest PATH] OBJECT...
;

const ParsedArgs = struct {
    output_path: []const u8 = "a.out",
    entry_symbol: []const u8 = "_start",
    output_kind: tldr.model.OutputKind = .executable,
    pie: bool = false,
    dynamic_linker: ?[]const u8 = null,
    soname: ?[]const u8 = null,
    export_dynamic: bool = false,
    eh_frame_header: bool = false,
    gc_sections: bool = false,
    strip_debug: bool = false,
    build_id: tldr.model.BuildIdMode = .none,
    icf: tldr.model.IcfMode = .off,
    incremental_mode: tldr.model.IncrementalMode = .off,
    incremental_manifest_path: ?[]const u8 = null,
    link_map_path: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    input_paths: []const []const u8,
};

const LoadedInputs = struct {
    files: std.ArrayListUnmanaged(LoadedInputFile) = .empty,
    inputs: std.ArrayListUnmanaged(tldr.Input) = .empty,
    prefault: ?sys.thread.JoinHandle = null,
    prefault_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn deinit(self: *LoadedInputs, allocator: Allocator) void {
        if (self.prefault) |handle| {
            self.prefault_stop.store(true, .release);
            handle.join();
        }
        for (self.files.items) |*file| file.deinit();
        self.files.deinit(allocator);
        self.inputs.deinit(allocator);
    }

    fn startPrefault(self: *LoadedInputs) void {
        if (self.prefault != null) return;
        if (!prefaultInputs(self.totalBytes())) return;
        self.prefault_stop.store(false, .release);
        self.prefault = sys.thread.spawn(prefaultMappedInputs, .{self}) catch null;
    }

    fn totalBytes(self: *const LoadedInputs) usize {
        var total: usize = 0;
        for (self.inputs.items) |input| total += input.bytes.len;
        return total;
    }
};

const LoadedInputFile = struct {
    bytes: []const u8 = "",
    mapping: ?[]align(std.heap.page_size_min) u8 = null,
    identity: ?tldr.InputIdentity = null,

    fn deinit(self: *LoadedInputFile) void {
        if (self.mapping) |mapping| sys.memory.unmap(mapping);
        self.* = .{};
    }
};

const MappedOutput = struct {
    path: []const u8,
    output_path: []const u8,
    sideline_path: []const u8,
    file: std.Io.File,
    file_open: bool = true,
    active: bool = true,
    delivered: bool = false,
    sideline: ?Sideline = null,

    const Sideline = struct {
        unlink_thread: ?sys.thread.JoinHandle = null,
    };

    fn init(allocator: Allocator, cwd: std.Io.Dir, output_path: []const u8) !MappedOutput {
        const path = try mappedOutputTempPath(allocator, output_path);
        const sideline_path = try mappedOutputSidelinePath(allocator, output_path);
        const file = try cwd.createFile(sys.fs.debugIo(), path, .{
            .read = true,
            .truncate = true,
        });
        return .{
            .path = path,
            .output_path = output_path,
            .sideline_path = sideline_path,
            .file = file,
        };
    }

    fn commitObserver(self: *MappedOutput) tldr.LinkCommitObserver {
        return .{ .context = self, .committed = onLinkCommitted };
    }

    fn onLinkCommitted(context: *anyopaque) void {
        const self: *MappedOutput = @ptrCast(@alignCast(context));
        if (self.sideline != null) return;
        const cwd = sys.fs.cwd();
        const stat = cwd.statFile(sys.fs.debugIo(), self.output_path, .{ .follow_symlinks = false }) catch return;
        switch (stat.kind) {
            .file, .sym_link => {},
            else => return,
        }
        cwd.rename(self.output_path, cwd, self.sideline_path, sys.fs.debugIo()) catch return;
        self.sideline = .{
            .unlink_thread = sys.thread.spawn(unlinkSidelineFile, .{self.sideline_path}) catch null,
        };
    }

    fn finish(self: *MappedOutput, cwd: std.Io.Dir) !void {
        if (self.file_open) {
            try self.file.setPermissions(sys.fs.debugIo(), .executable_file);
            self.file.close(sys.fs.debugIo());
            self.file_open = false;
        }
        try cwd.rename(self.path, cwd, self.output_path, sys.fs.debugIo());
        self.active = false;
        self.deliver(cwd);
    }

    fn deliver(self: *MappedOutput, cwd: std.Io.Dir) void {
        self.delivered = true;
        self.resolveSideline(cwd);
    }

    fn resolveSideline(self: *MappedOutput, cwd: std.Io.Dir) void {
        const sideline = self.sideline orelse return;
        self.sideline = null;
        if (sideline.unlink_thread) |thread| {
            thread.join();
            return;
        }
        if (self.delivered) {
            cwd.deleteFile(sys.fs.debugIo(), self.sideline_path) catch {};
        } else {
            cwd.rename(self.sideline_path, cwd, self.output_path, sys.fs.debugIo()) catch {};
        }
    }

    fn deinit(self: *MappedOutput, cwd: std.Io.Dir) void {
        self.resolveSideline(cwd);
        if (self.file_open) {
            self.file.close(sys.fs.debugIo());
            self.file_open = false;
        }
        if (self.active) {
            cwd.deleteFile(sys.fs.debugIo(), self.path) catch {};
            self.active = false;
        }
    }
};

pub fn main(init: sys.process.Init) !void {
    if (builtin.mode == .debug) {
        var debug_allocator: std.heap.DebugAllocator(.{}) = .{};
        const exit_code = try mainExitCode(init, debug_allocator.allocator());
        if (debug_allocator.deinit() == .leak) sys.process.exit(1);
        sys.process.exit(exit_code);
    }

    const exit_code = try mainExitCode(init, sys.allocator.processAllocator());
    sys.process.exit(exit_code);
}

fn unlinkSidelineFile(path: []const u8) void {
    sys.fs.cwd().deleteFile(sys.fs.debugIo(), path) catch {};
}

fn mappedOutputTempPath(allocator: Allocator, output_path: []const u8) ![]u8 {
    const stamp: u64 = @truncate(@as(u128, @bitCast(sys.time.realNanoTimestamp())));
    return try std.fmt.allocPrint(allocator, "{s}.tldr-tmp-{x}", .{ output_path, stamp });
}

fn mappedOutputSidelinePath(allocator: Allocator, output_path: []const u8) ![]u8 {
    const stamp: u64 = @truncate(@as(u128, @bitCast(sys.time.realNanoTimestamp())));
    return try std.fmt.allocPrint(allocator, "{s}.tldr-old-{x}", .{ output_path, stamp });
}

fn mainExitCode(init: sys.process.Init, allocator: Allocator) !u8 {
    const exit_code: u8 = blk: {
        var args_arena = std.heap.ArenaAllocator.init(allocator);
        defer args_arena.deinit();
        const argv = try init.minimal.args.toSlice(args_arena.allocator());

        const stderr_file = sys.stdio.stderr();
        const options = prettyOptions(stderr_file);
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = stderr_file.writer(sys.stdio.debugIo(), &stderr_buffer);
        var stderr_text_buffer: [4096]u8 = undefined;
        var stderr_text = pretty.TextWriter.init(
            &stderr_writer.interface,
            &stderr_text_buffer,
            options,
        );
        const stderr = &stderr_text.writer;
        const code = run(allocator, argv[1..], stderr, options) catch |err| code_blk: {
            try pretty_usage.writeErrorText(
                allocator,
                stderr,
                "tldr-link",
                @errorName(err),
                .{ .layout = options },
            );
            break :code_blk 1;
        };
        try stderr.flush();
        try stderr_writer.interface.flush();
        break :blk code;
    };

    return exit_code;
}

pub fn run(
    allocator: Allocator,
    args: []const []const u8,
    stderr: *std.Io.Writer,
    options: pretty.LayoutOptions,
) !u8 {
    return try runNamed(allocator, args, stderr, options, "tldr-link");
}

pub fn runNamed(
    allocator: Allocator,
    args: []const []const u8,
    stderr: *std.Io.Writer,
    options: pretty.LayoutOptions,
    command_name: []const u8,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (pretty_usage.hasHelpArg(args)) {
        try writeUsageNamed(allocator, stderr, options, command_name);
        return 0;
    }

    const parsed = parseArgs(arena, args) catch |err| switch (err) {
        error.InvalidArguments => {
            try writeUsageNamed(allocator, stderr, options, command_name);
            return 2;
        },
        else => return err,
    };
    if (parsed.input_paths.len == 0) {
        try writeUsageNamed(allocator, stderr, options, command_name);
        return 2;
    }
    if (parsed.incremental_mode == .relink and parsed.incremental_manifest_path == null) {
        try writeUsageNamed(allocator, stderr, options, command_name);
        return 2;
    }

    const inputs_read_at_ns = std.math.lossyCast(i64, sys.time.realNanoTimestamp());
    var loaded_inputs = try loadInputs(allocator, parsed.input_paths);
    defer loaded_inputs.deinit(allocator);
    if (parsed.incremental_mode != .relink) loaded_inputs.startPrefault();

    var diagnostics: tldr.Diagnostics = .{};
    var link_options: tldr.LinkOptions = .{
        .inputs_read_at_ns = inputs_read_at_ns,
        .output_kind = parsed.output_kind,
        .entry_symbol = parsed.entry_symbol,
        .pie = parsed.pie,
        .dynamic_linker = parsed.dynamic_linker,
        .soname = parsed.soname,
        .export_dynamic = parsed.export_dynamic,
        .eh_frame_header = parsed.eh_frame_header,
        .gc_sections = parsed.gc_sections,
        .strip_debug = parsed.strip_debug,
        .build_id = parsed.build_id,
        .icf = parsed.icf,
        .incremental_mode = parsed.incremental_mode,
        .diagnostics = &diagnostics,
    };
    const timing_phases = beginPhaseTimings();
    if (parsed.incremental_mode == .relink) {
        const relink_start = sys.time.nanoTimestamp();
        const status = try runRelink(arena, parsed, &loaded_inputs, link_options, stderr, options, &diagnostics);
        if (timing_phases) {
            const elapsed = sys.time.nanoTimestamp() - relink_start;
            finishPhaseTimings(stderr, if (elapsed < 0) 0 else @intCast(elapsed));
        }
        return status;
    }

    const link_start = sys.time.nanoTimestamp();
    var mapped_output = try MappedOutput.init(arena, sys.fs.cwd(), parsed.output_path);
    defer mapped_output.deinit(sys.fs.cwd());
    link_options.mapped_output_file = mapped_output.file;
    link_options.commit_observer = mapped_output.commitObserver();
    var linked = tldr.link(arena, loaded_inputs.inputs.items, link_options) catch |err| {
        try writeLinkFailure(arena, stderr, options, diagnostics.linkFailure(err));
        return 1;
    };
    if (timing_phases) {
        const elapsed = sys.time.nanoTimestamp() - link_start;
        finishPhaseTimings(stderr, if (elapsed < 0) 0 else @intCast(elapsed));
    }
    defer linked.deinit(arena);

    if (linked.isMaterialized()) {
        try mapped_output.finish(sys.fs.cwd());
    } else {
        try writeExecutableFile(sys.fs.cwd(), parsed.output_path, linked.bytes);
        mapped_output.deliver(sys.fs.cwd());
    }

    var prepared_state: ?tldr.incremental.PreparedState = if (parsed.incremental_mode == .prepare)
        try linked.prepareIncrementalState(arena)
    else
        null;
    defer if (prepared_state) |*state| state.deinit(arena);
    const manifest = if (prepared_state) |*state| state.manifest else linked.manifest;
    if (parsed.link_map_path) |link_map_path| {
        const link_map = try manifest.formatTextAlloc(arena);
        try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{
            .sub_path = link_map_path,
            .data = link_map,
            .flags = .{ .truncate = true },
        });
    }
    if (parsed.manifest_path) |manifest_path| {
        const manifest_binary = try manifest.formatBinaryAlloc(arena);
        try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{
            .sub_path = manifest_path,
            .data = manifest_binary,
            .flags = .{ .truncate = true },
        });
    }
    return 0;
}

const phase_timings_env = "TLDR_PHASE_TIMINGS";

var phase_timers: tldr.trace.PhaseTimers = .{};

fn phaseTimingsRequested() bool {
    const text = sys.env.get(phase_timings_env) orelse return false;
    return !std.mem.eql(u8, text, "0");
}

fn beginPhaseTimings() bool {
    if (!phaseTimingsRequested()) return false;
    tldr.trace.beginPhaseTiming(&phase_timers, &sys.time.nanoTimestamp);
    return true;
}

fn finishPhaseTimings(stderr: *std.Io.Writer, total_ns: u64) void {
    tldr.trace.endPhaseTiming();
    stderr.print("tldr phase timings (total {d:.3}ms):\n", .{@as(f64, @floatFromInt(total_ns)) / 1_000_000.0}) catch return;
    for (tldr.model.product_stage_order) |stage| {
        if (phase_timers.callCount(stage) == 0) continue;
        const stage_ns = phase_timers.totalNs(stage);
        const pct = if (total_ns == 0) 0.0 else @as(f64, @floatFromInt(stage_ns)) * 100.0 / @as(f64, @floatFromInt(total_ns));
        stderr.print(
            "  {s:<28} {d:>9.3}ms  {d:>5.1}%  calls={d}\n",
            .{ stage.label(), @as(f64, @floatFromInt(stage_ns)) / 1_000_000.0, pct, phase_timers.callCount(stage) },
        ) catch return;
    }
    stderr.flush() catch {};
}

fn loadInputs(allocator: Allocator, paths: []const []const u8) !LoadedInputs {
    var loaded: LoadedInputs = .{};
    errdefer loaded.deinit(allocator);
    var first_cached_archive_path: ?[]const u8 = null;
    var first_cached_archive_index: usize = 0;
    var cached_archive_paths: std.StringHashMapUnmanaged(usize) = .empty;
    defer cached_archive_paths.deinit(allocator);

    try loaded.files.ensureTotalCapacity(allocator, paths.len);
    try loaded.inputs.ensureTotalCapacity(allocator, paths.len);
    for (paths) |path| {
        if (cacheableInputPath(path)) {
            if (first_cached_archive_path) |first_path| {
                if (std.mem.eql(u8, path, first_path)) {
                    appendCachedInput(&loaded, path, first_cached_archive_index);
                    continue;
                }
                if (cached_archive_paths.count() == 0) {
                    try cached_archive_paths.ensureTotalCapacity(allocator, 4);
                    cached_archive_paths.putAssumeCapacityNoClobber(first_path, first_cached_archive_index);
                }
                const gop = try cached_archive_paths.getOrPut(allocator, path);
                if (gop.found_existing) {
                    appendCachedInput(&loaded, path, gop.value_ptr.*);
                    continue;
                }
                gop.value_ptr.* = loaded.files.items.len;
            } else {
                first_cached_archive_path = path;
                first_cached_archive_index = loaded.files.items.len;
            }
        }
        const file = try loadInputFile(path);
        loaded.files.appendAssumeCapacity(file);
        loaded.inputs.appendAssumeCapacity(.{
            .name = path,
            .bytes = file.bytes,
            .identity = file.identity,
        });
    }
    return loaded;
}

fn appendCachedInput(loaded: *LoadedInputs, path: []const u8, file_index: usize) void {
    const file = loaded.files.items[file_index];
    loaded.inputs.appendAssumeCapacity(.{
        .name = path,
        .bytes = file.bytes,
        .identity = file.identity,
    });
}

fn cacheableInputPath(path: []const u8) bool {
    return path.len >= 2 and path[path.len - 2] == '.' and path[path.len - 1] == 'a';
}

fn prefaultInputs(total_bytes: usize) bool {
    return sys.thread.threadsSupported() and total_bytes >= prefault_input_threshold;
}

fn prefaultMappedInputs(loaded: *LoadedInputs) void {
    const page_size = sys.memory.pageSize();
    var sink: u8 = 0;
    outer: for (loaded.files.items) |file| {
        const bytes = file.bytes;
        if (bytes.len == 0) continue;
        var offset: usize = 0;
        var pages: usize = 0;
        while (offset < bytes.len) : (offset += page_size) {
            if (loaded.prefault_stop.load(.acquire)) break :outer;
            const byte: *const volatile u8 = @ptrCast(&bytes[offset]);
            sink ^= byte.*;
            pages += 1;
            if ((pages & 0xff) == 0) {
                if (loaded.prefault_stop.load(.acquire)) break :outer;
                sys.thread.yield();
            }
        }
        if (loaded.prefault_stop.load(.acquire)) break;
        const last: *const volatile u8 = @ptrCast(&bytes[bytes.len - 1]);
        sink ^= last.*;
    }
    std.mem.doNotOptimizeAway(sink);
}

fn loadInputFile(path: []const u8) !LoadedInputFile {
    var file = if (std.fs.path.isAbsolute(path))
        try sys.fs.openAbsoluteFile(path, .{})
    else
        try sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{});
    defer file.close(sys.fs.debugIo());

    const stat = try file.stat(sys.fs.debugIo());
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (size > max_object_bytes) return error.FileTooBig;
    const identity: ?tldr.InputIdentity = if (std.math.cast(i64, stat.mtime.nanoseconds)) |mtime_ns| .{
        .mtime_ns = mtime_ns,
        .inode = stat.inode,
    } else null;
    if (size == 0) return .{ .identity = identity };

    const mapping = try sys.memory.mapPrivateFile(file.handle, size, .{ .read = true }, 0);
    return .{
        .bytes = mapping[0..size],
        .mapping = mapping,
        .identity = identity,
    };
}

fn runRelink(
    allocator: Allocator,
    parsed: ParsedArgs,
    loaded: *LoadedInputs,
    options: tldr.LinkOptions,
    stderr: *std.Io.Writer,
    output_options: pretty.LayoutOptions,
    diagnostics: *tldr.Diagnostics,
) !u8 {
    const inputs = loaded.inputs.items;
    const manifest_input_path = parsed.incremental_manifest_path.?;
    const cwd = sys.fs.cwd();
    const decode_phase = tldr.trace.product(.relink_manifest_decode);
    var manifest_source = try MappedManifest.open(cwd, manifest_input_path);
    defer manifest_source.deinit();
    const previous_manifest_bytes = manifest_source.bytes;

    const previous_manifest = tldr.incremental.Manifest.fromBinary(allocator, previous_manifest_bytes) catch |err| switch (err) {
        error.UnsupportedManifestProtocol, error.InvalidManifestBinary => {
            decode_phase.end();
            loaded.startPrefault();
            return try runRelinkFullLink(allocator, parsed, inputs, options, stderr, output_options, diagnostics, manifest_input_path);
        },
        else => return err,
    };
    var state = try tldr.incremental.PreparedState.fromOwnedManifest(allocator, previous_manifest);
    defer state.deinit(allocator);
    decode_phase.end();

    var output_present = true;
    cwd.access(sys.fs.debugIo(), parsed.output_path, .{}) catch |err| switch (err) {
        error.FileNotFound => output_present = false,
        else => return err,
    };
    const reuse = detect_reuse: {
        const change_phase = tldr.trace.product(.relink_change_detection);
        defer change_phase.end();
        break :detect_reuse output_present and state.canReuseFor(options, inputs);
    };
    if (reuse) {
        try writeRelinkSidecars(allocator, cwd, parsed, state.manifest, manifest_input_path, false);
        return 0;
    }

    const input_change_limits = tldr.incremental.InputChangeStorage.Limits.inspect(
        tldr.incremental.RecordedInputs.fromManifest(&state.manifest),
        inputs,
    );
    const input_change_capacity = try tldr.incremental.InputChangeStorage.Capacity.derive(
        input_change_limits,
    );
    const input_change_bytes = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(tldr.incremental.InputChangeStorage.storage_alignment),
        input_change_capacity.storage_bytes,
    );
    defer allocator.free(input_change_bytes);
    var input_change_storage = try tldr.incremental.InputChangeStorage.init(
        input_change_bytes,
        input_change_limits,
    );
    defer _ = input_change_storage.deinit();
    input_change_storage.activate();
    const input_changes = classify: {
        const change_phase = tldr.trace.product(.relink_change_detection);
        defer change_phase.end();
        break :classify try state.classifyInputs(
            &input_change_storage,
            inputs,
        );
    };

    var replacements: []const tldr.incremental.ReplacementContribution = &.{};
    var replacements_owned = false;
    defer if (replacements_owned) tldr.incremental.freeReplacementContributions(allocator, replacements);

    var relink_plan = state.planChangedInputRelinkFromInputChanges(options, input_changes, replacements);
    var direct_evidence: tldr.incremental.DirectRelinkEvidence = .{};
    defer direct_evidence.deinit(allocator);
    var direct_inputs_proven = false;
    if (relinkNeedsCandidateReplacements(relink_plan, input_changes)) {
        const evidence_phase = tldr.trace.product(.relink_direct_evidence);
        defer evidence_phase.end();
        direct_evidence = tldr.directIncrementalEvidenceAlloc(
            allocator,
            state.manifest,
            inputs,
            input_changes,
            options,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .{},
        };
        replacements = direct_evidence.replacements;
        if (replacements.len != 0) {
            if (state.ensureReplacementIndex(allocator, replacements)) {
                relink_plan = state.planChangedInputRelinkFromInputChanges(options, input_changes, replacements);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.DuplicateContribution => {},
            }
        }
        direct_inputs_proven = direct_evidence.inputs_proven;
    }

    var use_in_place = false;
    var manifest_updates: ?tldr.incremental.PreparedState.RecordUpdates = null;
    defer if (manifest_updates) |*updates| updates.deinit(allocator);
    var patch_target: ?MappedPatchOutput = null;
    defer if (patch_target) |*target| target.deinit();
    var patched_ranges: std.ArrayListUnmanaged(tldr.incremental.FileRange) = .empty;
    defer patched_ranges.deinit(allocator);
    var candidate: ?tldr.LinkedImage = null;
    defer if (candidate) |*linked| linked.deinit(allocator);
    var mapped_output: ?MappedOutput = null;
    defer if (mapped_output) |*output| output.deinit(cwd);

    if (relink_plan.decision == .in_place and direct_inputs_proven) {
        {
            const io_phase = tldr.trace.product(.relink_output_io);
            defer io_phase.end();
            patch_target = try MappedPatchOutput.open(cwd, parsed.output_path);
        }
        if (patch_target) |target| {
            const patch_phase = tldr.trace.product(.relink_patch_apply);
            defer patch_phase.end();
            const application = try state.applyAcceptedChangedInputRelink(
                target.mapping,
                replacements,
                relink_plan,
            );
            if (application.plan.decision == .in_place) {
                use_in_place = try finishInPlaceDirectRelink(
                    &state,
                    target.mapping,
                    options,
                    inputs,
                    input_changes,
                    replacements,
                    direct_evidence.member_updates,
                    relink_plan,
                );
            }
            if (use_in_place) {
                try appendReplacementRanges(allocator, &patched_ranges, &state, replacements);
                if (try tldr.incrementalBuildIdNoteRange(target.mapping, options)) |range| {
                    try patched_ranges.append(allocator, .{ .offset = range.offset, .len = range.len });
                }
                manifest_updates = try state.acceptedRelinkRecordUpdates(
                    allocator,
                    inputs,
                    input_changes,
                    replacements,
                    direct_evidence.member_updates,
                );
            }
        }
        if (!use_in_place) {
            if (patch_target) |*target| target.deinit();
            patch_target = null;
        }
    }

    if (!use_in_place) {
        loaded.startPrefault();
        mapped_output = try MappedOutput.init(allocator, cwd, parsed.output_path);
        var candidate_options = options;
        candidate_options.mapped_output_file = mapped_output.?.file;
        candidate = tldr.link(allocator, inputs, candidate_options) catch |err| {
            try writeLinkFailure(allocator, stderr, output_options, diagnostics.linkFailure(err));
            return 1;
        };

        if (relinkNeedsCandidateReplacements(relink_plan, input_changes)) {
            if (replacements_owned) {
                tldr.incremental.freeReplacementContributions(allocator, replacements);
                replacements_owned = false;
            }
            replacements = try tldr.incremental.replacementContributionsFromImage(
                allocator,
                candidate.?.bytes,
                candidate.?.manifest,
                input_changes,
            );
            replacements_owned = replacements.len != 0;
            if (state.ensureReplacementIndex(allocator, replacements)) {
                relink_plan = state.planChangedInputRelinkFromInputChanges(options, input_changes, replacements);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.DuplicateContribution => {},
            }
        }

        if (relink_plan.decision != .full_link) {
            {
                const io_phase = tldr.trace.product(.relink_output_io);
                defer io_phase.end();
                patch_target = try MappedPatchOutput.open(cwd, parsed.output_path);
            }
            if (patch_target) |target| {
                const patch_phase = tldr.trace.product(.relink_patch_apply);
                defer patch_phase.end();
                const application = try state.applyAcceptedChangedInputRelink(
                    target.mapping,
                    replacements,
                    relink_plan,
                );
                if (application.plan.decision == .in_place) {
                    use_in_place = try finishInPlaceCandidateRelink(
                        allocator,
                        &state,
                        target.mapping,
                        candidate.?.bytes,
                        candidate.?.manifest,
                        options,
                        inputs,
                        input_changes,
                        replacements,
                        relink_plan,
                    );
                }
                if (use_in_place) {
                    try appendReplacementRanges(allocator, &patched_ranges, &state, replacements);
                    if (try tldr.incrementalMetadataPatchRange(target.mapping, options)) |range| {
                        try patched_ranges.append(allocator, .{ .offset = range.offset, .len = range.len });
                    }
                    if (try tldr.incrementalBuildIdNoteRange(target.mapping, options)) |range| {
                        try patched_ranges.append(allocator, .{ .offset = range.offset, .len = range.len });
                    }
                }
            }
            if (!use_in_place) {
                if (patch_target) |*target| target.deinit();
                patch_target = null;
            }
        }
    }
    const final_manifest = if (use_in_place) state.manifest else candidate.?.manifest;

    if (use_in_place) {
        const io_phase = tldr.trace.product(.relink_output_io);
        defer io_phase.end();
        try writeMappedRanges(cwd, parsed.output_path, patch_target.?.mapping, patched_ranges.items);
        if (manifest_updates) |updates| {
            if (try writeRelinkManifestPatches(
                allocator,
                cwd,
                parsed,
                state.manifest,
                previous_manifest_bytes,
                manifest_input_path,
                updates,
            )) {
                try writeRelinkLinkMap(allocator, cwd, parsed, state.manifest);
                return 0;
            }
        }
    } else if (candidate.?.isMaterialized()) {
        if (mapped_output) |*output| {
            try output.finish(cwd);
        } else {
            return error.OutputFileError;
        }
    } else {
        try writeExecutableFile(cwd, parsed.output_path, candidate.?.bytes);
    }
    try writeRelinkSidecars(allocator, cwd, parsed, final_manifest, manifest_input_path, true);
    return 0;
}

fn runRelinkFullLink(
    allocator: Allocator,
    parsed: ParsedArgs,
    inputs: []const tldr.Input,
    options: tldr.LinkOptions,
    stderr: *std.Io.Writer,
    output_options: pretty.LayoutOptions,
    diagnostics: *tldr.Diagnostics,
    manifest_input_path: []const u8,
) !u8 {
    const cwd = sys.fs.cwd();
    var mapped_output = try MappedOutput.init(allocator, cwd, parsed.output_path);
    defer mapped_output.deinit(cwd);
    var candidate_options = options;
    candidate_options.mapped_output_file = mapped_output.file;
    var linked = tldr.link(allocator, inputs, candidate_options) catch |err| {
        try writeLinkFailure(allocator, stderr, output_options, diagnostics.linkFailure(err));
        return 1;
    };
    defer linked.deinit(allocator);

    if (linked.isMaterialized()) {
        try mapped_output.finish(cwd);
    } else {
        try writeExecutableFile(cwd, parsed.output_path, linked.bytes);
    }
    try writeRelinkSidecars(allocator, cwd, parsed, linked.manifest, manifest_input_path, true);
    return 0;
}

const MappedManifest = struct {
    bytes: []u8 = &.{},
    mapping: ?[]align(std.heap.page_size_min) u8 = null,

    fn open(cwd: std.Io.Dir, path: []const u8) !MappedManifest {
        var file = if (std.fs.path.isAbsolute(path))
            try sys.fs.openAbsoluteFile(path, .{})
        else
            try cwd.openFile(sys.fs.debugIo(), path, .{});
        defer file.close(sys.fs.debugIo());

        const stat = try file.stat(sys.fs.debugIo());
        const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        if (size > max_object_bytes) return error.FileTooBig;
        if (size == 0) return .{};

        const mapping = try sys.memory.mapPrivateFile(file.handle, size, .{ .read = true, .write = true }, 0);
        return .{
            .bytes = mapping[0..size],
            .mapping = mapping,
        };
    }

    fn deinit(self: *MappedManifest) void {
        if (self.mapping) |mapping| sys.memory.unmap(mapping);
        self.* = .{};
    }
};

const MappedPatchOutput = struct {
    raw: []align(std.heap.page_size_min) u8,
    mapping: []u8,

    fn open(cwd: std.Io.Dir, path: []const u8) !?MappedPatchOutput {
        var file = cwd.openFile(sys.fs.debugIo(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(sys.fs.debugIo());
        const stat = try file.stat(sys.fs.debugIo());
        const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        if (size == 0) return null;
        const raw = try sys.memory.mapPrivateFile(file.handle, size, .{ .read = true, .write = true }, 0);
        return .{ .raw = raw, .mapping = raw[0..size] };
    }

    fn deinit(self: *MappedPatchOutput) void {
        sys.memory.unmap(self.raw);
        self.* = undefined;
    }
};

fn appendReplacementRanges(
    allocator: Allocator,
    ranges: *std.ArrayListUnmanaged(tldr.incremental.FileRange),
    state: *const tldr.incremental.PreparedState,
    replacements: []const tldr.incremental.ReplacementContribution,
) !void {
    for (replacements) |replacement| {
        if (state.replacementFileRange(replacement)) |range| {
            try ranges.append(allocator, range);
        }
    }
}

fn writeMappedRanges(
    cwd: std.Io.Dir,
    path: []const u8,
    image: []const u8,
    ranges: []const tldr.incremental.FileRange,
) !void {
    var file = try cwd.openFile(sys.fs.debugIo(), path, .{ .mode = .write_only });
    defer file.close(sys.fs.debugIo());
    for (ranges) |range| {
        if (range.offset >= image.len) continue;
        const end = @min(range.offset + range.len, image.len);
        if (range.offset >= end) continue;
        try sys.fs.writeHandleAt(file, image[range.offset..end], range.offset);
    }
    try cwd.setFilePermissions(sys.fs.debugIo(), path, .executable_file, .{});
}

fn writeExecutableFile(cwd: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    try cwd.writeFile(sys.fs.debugIo(), .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
    try cwd.setFilePermissions(sys.fs.debugIo(), path, .executable_file, .{});
}

fn relinkNeedsCandidateReplacements(
    plan: tldr.incremental.RelinkPlan,
    input_changes: tldr.incremental.InputChanges,
) bool {
    if (plan.decision == .full_link and plan.blocker == .replacement_missing) return true;
    return plan.decision == .in_place and input_changes.summary.changed != 0;
}

fn finishInPlaceDirectRelink(
    state: *tldr.incremental.PreparedState,
    output: []u8,
    options: tldr.LinkOptions,
    inputs: []const tldr.Input,
    input_changes: tldr.incremental.InputChanges,
    replacements: []const tldr.incremental.ReplacementContribution,
    member_updates: []const tldr.incremental.MemberHashUpdate,
    relink_plan: tldr.incremental.RelinkPlan,
) Allocator.Error!bool {
    tldr.finishDirectIncrementalMetadataPatch(output, options) catch return false;
    state.updateManifestForAcceptedChangedInputRelinkFromInputChanges(
        inputs,
        input_changes,
        replacements,
        member_updates,
        options.inputs_read_at_ns,
        relink_plan,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RelinkUpdateRequiresInPlacePlan,
        error.ReplacementMissing,
        error.MemberMissing,
        error.SectionLayoutChanged,
        => return false,
    };
    return true;
}

fn writeRelinkLinkMap(
    allocator: Allocator,
    cwd: std.Io.Dir,
    parsed: ParsedArgs,
    manifest: tldr.incremental.Manifest,
) !void {
    if (parsed.link_map_path) |link_map_path| {
        const link_map = try manifest.formatTextAlloc(allocator);
        try cwd.writeFile(sys.fs.debugIo(), .{
            .sub_path = link_map_path,
            .data = link_map,
            .flags = .{ .truncate = true },
        });
    }
}

fn writeRelinkManifestPatches(
    allocator: Allocator,
    cwd: std.Io.Dir,
    parsed: ParsedArgs,
    manifest: tldr.incremental.Manifest,
    encoded: []const u8,
    manifest_input_path: []const u8,
    updates: tldr.incremental.PreparedState.RecordUpdates,
) !bool {
    const manifest_output_path = parsed.manifest_path orelse manifest_input_path;
    if (!std.mem.eql(u8, manifest_output_path, manifest_input_path)) return false;
    const patches = manifest.scalarPatchesAlloc(
        allocator,
        encoded,
        updates.input_indexes.items,
        updates.contribution_indexes.items,
        updates.archive_member_indexes.items,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer allocator.free(patches);
    var file = cwd.openFile(sys.fs.debugIo(), manifest_input_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(sys.fs.debugIo());
    for (patches) |patch| {
        try sys.fs.writeHandleAt(file, patch.slice(), patch.offset);
    }
    return true;
}

fn writeRelinkSidecars(
    allocator: Allocator,
    cwd: std.Io.Dir,
    parsed: ParsedArgs,
    manifest: tldr.incremental.Manifest,
    manifest_input_path: []const u8,
    manifest_dirty: bool,
) !void {
    try writeRelinkLinkMap(allocator, cwd, parsed, manifest);

    if (parsed.incremental_manifest_path != null or parsed.manifest_path != null) {
        const manifest_output_path = parsed.manifest_path orelse if (parsed.incremental_manifest_path != null) manifest_input_path else null;
        if (manifest_output_path) |path| {
            if (!manifest_dirty and std.mem.eql(u8, path, manifest_input_path)) return;
            const manifest_binary = try manifest.formatBinaryAlloc(allocator);
            try cwd.writeFile(sys.fs.debugIo(), .{
                .sub_path = path,
                .data = manifest_binary,
                .flags = .{ .truncate = true },
            });
        }
    }
}

fn finishInPlaceCandidateRelink(
    allocator: Allocator,
    state: *tldr.incremental.PreparedState,
    previous_output: []u8,
    candidate_bytes: []const u8,
    candidate_manifest: tldr.incremental.Manifest,
    options: tldr.LinkOptions,
    inputs: []const tldr.Input,
    input_changes: tldr.incremental.InputChanges,
    replacements: []const tldr.incremental.ReplacementContribution,
    relink_plan: tldr.incremental.RelinkPlan,
) Allocator.Error!bool {
    tldr.applyIncrementalMetadataPatch(previous_output, candidate_bytes, options) catch return false;
    state.updateManifestForAcceptedCandidateRelinkFromInputChanges(
        allocator,
        inputs,
        input_changes,
        replacements,
        candidate_manifest,
        relink_plan,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RelinkUpdateRequiresInPlacePlan,
        error.ReplacementMissing,
        error.MemberMissing,
        error.SectionLayoutChanged,
        => return false,
    };
    return true;
}

fn writeUsageNamed(
    allocator: Allocator,
    stderr: *std.Io.Writer,
    options: pretty.LayoutOptions,
    command_name: []const u8,
) !void {
    const text = try usageTextAlloc(allocator, command_name);
    defer allocator.free(text);
    try pretty_usage.writeUsageText(allocator, stderr, text, .{ .layout = options });
}

fn usageTextAlloc(allocator: Allocator, command_name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, command_name, "tldr-link")) return try allocator.dupe(u8, usage_text);
    const prefix = try std.fmt.allocPrint(allocator, "usage: {s}", .{command_name});
    defer allocator.free(prefix);
    return try std.mem.replaceOwned(u8, allocator, usage_text, "usage: tldr-link", prefix);
}

fn writeLinkFailure(
    allocator: Allocator,
    stderr: *std.Io.Writer,
    options: pretty.LayoutOptions,
    failure: tldr.Diagnostics.LinkFailure,
) !void {
    const rendered = try renderLinkFailureAlloc(allocator, options, failure);
    defer allocator.free(rendered);
    try stderr.writeAll(rendered);
}

fn renderLinkFailureAlloc(
    allocator: Allocator,
    options: pretty.LayoutOptions,
    failure: tldr.Diagnostics.LinkFailure,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const builder = pretty.Builder.init(arena_state.allocator());
    const doc = try linkFailureDocAlloc(builder, failure);
    return try pretty.renderAlloc(allocator, doc, options);
}

fn linkFailureDocAlloc(
    builder: pretty.Builder,
    failure: tldr.Diagnostics.LinkFailure,
) !pretty.Doc {
    return switch (failure) {
        .undefined_symbols => |undefined_symbols| try undefinedSymbolsDocAlloc(builder, undefined_symbols),
        .undefined_symbol => |undefined_symbol| try lineWithPrefixDoc(
            builder,
            "TLDR link failed",
            .danger,
            try builder.concat(&.{
                builder.text("undefined symbol"),
                pretty.softline,
                try builder.styledText(.name, undefined_symbol.name),
                pretty.softline,
                builder.text("referenced by"),
                pretty.softline,
                try builder.styledText(.source, undefined_symbol.input_name),
            }),
        ),
        .unsupported_relocation => |relocation| try unsupportedRelocationDocAlloc(builder, relocation),
        .unsupported_input_format => |unsupported| try unsupportedInputFormatDocAlloc(builder, unsupported),
        .generic => |err| try lineWithPrefixDoc(
            builder,
            "TLDR link failed",
            .danger,
            builder.text(@errorName(err)),
        ),
    };
}

fn undefinedSymbolsDocAlloc(
    builder: pretty.Builder,
    undefined_symbols: tldr.Diagnostics.UndefinedSymbols,
) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    try parts.append(builder.allocator, try lineWithPrefixDoc(
        builder,
        "TLDR link failed",
        .danger,
        builder.text("undefined symbols"),
    ));
    for (undefined_symbols.symbols) |undefined_symbol| {
        try parts.append(builder.allocator, try builder.spaces(2));
        try parts.append(builder.allocator, try builder.group(try builder.nest(2, try builder.concat(&.{
            try builder.styledText(.name, undefined_symbol.name),
            pretty.softline,
            builder.text("referenced by"),
            pretty.softline,
            try builder.styledText(.source, undefined_symbol.input_name),
        }))));
        try parts.append(builder.allocator, pretty.hardline);
    }
    if (undefined_symbols.hidden_count != 0) {
        try parts.append(builder.allocator, try builder.spaces(2));
        try parts.append(builder.allocator, try builder.styledText(.muted, "... and "));
        try parts.append(builder.allocator, try builder.styledFmt(.number, "{d}", .{undefined_symbols.hidden_count}));
        try parts.append(builder.allocator, try builder.styledText(.muted, " more"));
        try parts.append(builder.allocator, pretty.hardline);
    }
    return try builder.concat(parts.items);
}

fn unsupportedRelocationDocAlloc(
    builder: pretty.Builder,
    relocation: tldr.Diagnostics.UnsupportedRelocation,
) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    try parts.append(builder.allocator, builder.text("unsupported relocation"));
    try parts.append(builder.allocator, pretty.softline);
    try parts.append(builder.allocator, try builder.styledFmt(.number, "{d}", .{relocation.relocation_type}));
    try parts.append(builder.allocator, pretty.softline);
    try parts.append(builder.allocator, builder.text("in"));
    try parts.append(builder.allocator, pretty.softline);
    try parts.append(builder.allocator, try builder.styledText(.source, relocation.input_name));
    try parts.append(builder.allocator, try builder.punct(":"));
    try parts.append(builder.allocator, try builder.styledText(.source, relocation.section_name));
    if (relocation.symbol_name.len != 0) {
        try parts.append(builder.allocator, pretty.softline);
        try parts.append(builder.allocator, builder.text("against"));
        try parts.append(builder.allocator, pretty.softline);
        try parts.append(builder.allocator, try builder.styledText(.name, relocation.symbol_name));
    }
    return try lineWithPrefixDoc(
        builder,
        "TLDR link failed",
        .danger,
        try builder.concat(parts.items),
    );
}

fn unsupportedInputFormatDocAlloc(
    builder: pretty.Builder,
    unsupported: tldr.Diagnostics.UnsupportedInputFormat,
) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    try parts.append(builder.allocator, builder.text("unsupported input format"));
    try parts.append(builder.allocator, pretty.softline);
    try parts.append(builder.allocator, try builder.styledText(.type_name, @tagName(unsupported.input_format)));
    try parts.append(builder.allocator, pretty.softline);
    try parts.append(builder.allocator, builder.text("in"));
    try parts.append(builder.allocator, pretty.softline);
    try parts.append(builder.allocator, try builder.styledText(.source, unsupported.input_name));
    if (unsupported.member_name) |member_name| {
        try parts.append(builder.allocator, try builder.punct("("));
        try parts.append(builder.allocator, try builder.styledText(.source, member_name));
        try parts.append(builder.allocator, try builder.punct(")"));
    }
    try parts.append(builder.allocator, pretty.softline);
    try parts.append(builder.allocator, builder.text("for"));
    try parts.append(builder.allocator, pretty.softline);
    try parts.append(builder.allocator, try builder.styledText(.type_name, @tagName(unsupported.target_format)));
    try parts.append(builder.allocator, pretty.softline);
    try parts.append(builder.allocator, builder.text("target"));
    return try lineWithPrefixDoc(
        builder,
        "TLDR link failed",
        .danger,
        try builder.concat(parts.items),
    );
}

fn lineWithPrefixDoc(
    builder: pretty.Builder,
    prefix: []const u8,
    style: pretty.Style,
    message: pretty.Doc,
) !pretty.Doc {
    return try builder.concat(&.{
        try builder.group(try builder.concat(&.{
            try builder.styledText(style, prefix),
            try builder.punct(":"),
            try builder.nest(prefix.len + 2, try builder.concat(&.{
                pretty.softline,
                message,
            })),
        })),
        pretty.hardline,
    });
}

fn prettyOptions(file: std.Io.File) pretty.LayoutOptions {
    return pretty_usage.layoutOptions(file, .{});
}

fn parseArgs(allocator: Allocator, args: []const []const u8) !ParsedArgs {
    const expanded = try expandArgs(allocator, args);
    var input_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var library_search_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var parsed: ParsedArgs = .{ .input_paths = &.{} };
    var static_library_search = false;

    var index: usize = 0;
    while (index < expanded.len) : (index += 1) {
        const arg = expanded[index];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= expanded.len) return error.InvalidArguments;
            parsed.output_path = expanded[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-o") and arg.len > 2) {
            parsed.output_path = arg[2..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--output=")) {
            parsed.output_path = arg["--output=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--entry")) {
            index += 1;
            if (index >= expanded.len) return error.InvalidArguments;
            parsed.entry_symbol = expanded[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-e") and arg.len > 2) {
            parsed.entry_symbol = arg[2..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--entry=")) {
            parsed.entry_symbol = arg["--entry=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--gc-sections")) {
            parsed.gc_sections = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-gc-sections")) {
            parsed.gc_sections = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strip-debug")) {
            parsed.strip_debug = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-strip-debug")) {
            parsed.strip_debug = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-pie") or std.mem.eql(u8, arg, "--pie")) {
            parsed.pie = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-no-pie") or std.mem.eql(u8, arg, "--no-pie")) {
            parsed.pie = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-static-pie")) {
            parsed.pie = true;
            static_library_search = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-shared") or std.mem.eql(u8, arg, "--shared")) {
            parsed.output_kind = .shared_library;
            continue;
        }
        if (std.mem.eql(u8, arg, "-dynamic-linker") or std.mem.eql(u8, arg, "--dynamic-linker")) {
            index += 1;
            if (index >= expanded.len or expanded[index].len == 0) return error.InvalidArguments;
            parsed.dynamic_linker = expanded[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-dynamic-linker=")) {
            const linker = arg["-dynamic-linker=".len..];
            if (linker.len == 0) return error.InvalidArguments;
            parsed.dynamic_linker = linker;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--dynamic-linker=")) {
            const linker = arg["--dynamic-linker=".len..];
            if (linker.len == 0) return error.InvalidArguments;
            parsed.dynamic_linker = linker;
            continue;
        }
        if (std.mem.eql(u8, arg, "-soname") or std.mem.eql(u8, arg, "--soname")) {
            index += 1;
            if (index >= expanded.len or expanded[index].len == 0) return error.InvalidArguments;
            parsed.soname = expanded[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-soname=")) {
            const soname = arg["-soname=".len..];
            if (soname.len == 0) return error.InvalidArguments;
            parsed.soname = soname;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--soname=")) {
            const soname = arg["--soname=".len..];
            if (soname.len == 0) return error.InvalidArguments;
            parsed.soname = soname;
            continue;
        }
        if (std.mem.eql(u8, arg, "--export-dynamic") or std.mem.eql(u8, arg, "-export-dynamic") or std.mem.eql(u8, arg, "-E")) {
            parsed.export_dynamic = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--eh-frame-hdr")) {
            parsed.eh_frame_header = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-eh-frame-hdr")) {
            parsed.eh_frame_header = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--library-path")) {
            index += 1;
            if (index >= expanded.len or expanded[index].len == 0) return error.InvalidArguments;
            try library_search_paths.append(allocator, expanded[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-L") and arg.len > 2) {
            try library_search_paths.append(allocator, arg[2..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--library-path=")) {
            const path = arg["--library-path=".len..];
            if (path.len == 0) return error.InvalidArguments;
            try library_search_paths.append(allocator, path);
            continue;
        }
        if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--library")) {
            index += 1;
            if (index >= expanded.len or expanded[index].len == 0) return error.InvalidArguments;
            try tldr.library.appendResolvedInputPaths(allocator, &input_paths, library_search_paths.items, expanded[index], static_library_search);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-l") and arg.len > 2) {
            try tldr.library.appendResolvedInputPaths(allocator, &input_paths, library_search_paths.items, arg[2..], static_library_search);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--library=")) {
            const library = arg["--library=".len..];
            if (library.len == 0) return error.InvalidArguments;
            try tldr.library.appendResolvedInputPaths(allocator, &input_paths, library_search_paths.items, library, static_library_search);
            continue;
        }
        if (std.mem.eql(u8, arg, "-static") or std.mem.eql(u8, arg, "--static") or std.mem.eql(u8, arg, "-Bstatic")) {
            static_library_search = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-Bdynamic") or std.mem.eql(u8, arg, "-bdynamic")) {
            static_library_search = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--start-group") or std.mem.eql(u8, arg, "--end-group") or std.mem.eql(u8, arg, "-(") or std.mem.eql(u8, arg, "-)")) continue;
        if (std.mem.eql(u8, arg, "--as-needed") or std.mem.eql(u8, arg, "--no-as-needed")) continue;
        if (std.mem.eql(u8, arg, "--enable-new-dtags") or std.mem.eql(u8, arg, "--disable-new-dtags")) continue;
        if (std.mem.eql(u8, arg, "-m")) {
            index += 1;
            if (index >= expanded.len or expanded[index].len == 0) return error.InvalidArguments;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-m") and arg.len > 2) continue;
        if (std.mem.eql(u8, arg, "-z")) {
            index += 1;
            if (index >= expanded.len or expanded[index].len == 0) return error.InvalidArguments;
            if (!supportedIgnoredZPolicy(expanded[index])) return error.InvalidArguments;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-z") and arg.len > 2) {
            if (!supportedIgnoredZPolicy(arg[2..])) return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "-rpath") or std.mem.eql(u8, arg, "--rpath")) {
            index += 1;
            if (index >= expanded.len or expanded[index].len == 0) return error.InvalidArguments;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-rpath=") or std.mem.startsWith(u8, arg, "--rpath=")) continue;
        if (std.mem.eql(u8, arg, "--build-id")) {
            parsed.build_id = .fast;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--build-id=")) {
            parsed.build_id = try parseBuildIdMode(arg["--build-id=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-build-id")) {
            parsed.build_id = .none;
            continue;
        }
        if (std.mem.eql(u8, arg, "--hash-style")) {
            index += 1;
            if (index >= expanded.len or !supportedStaticHashStyle(expanded[index])) return error.InvalidArguments;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--hash-style=")) {
            if (!supportedStaticHashStyle(arg["--hash-style=".len..])) return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--icf")) {
            index += 1;
            if (index >= expanded.len) return error.InvalidArguments;
            parsed.icf = try parseIcf(expanded[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--icf=")) {
            parsed.icf = try parseIcf(arg["--icf=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--incremental")) {
            index += 1;
            if (index >= expanded.len) return error.InvalidArguments;
            parsed.incremental_mode = try parseIncrementalMode(expanded[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--incremental=")) {
            parsed.incremental_mode = try parseIncrementalMode(arg["--incremental=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--incremental-manifest")) {
            index += 1;
            if (index >= expanded.len) return error.InvalidArguments;
            parsed.incremental_manifest_path = expanded[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--incremental-manifest=")) {
            parsed.incremental_manifest_path = arg["--incremental-manifest=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--emit-link-map")) {
            index += 1;
            if (index >= expanded.len) return error.InvalidArguments;
            parsed.link_map_path = expanded[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--emit-link-map=")) {
            parsed.link_map_path = arg["--emit-link-map=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "-Map") or std.mem.eql(u8, arg, "--Map") or std.mem.eql(u8, arg, "--map")) {
            index += 1;
            if (index >= expanded.len) return error.InvalidArguments;
            parsed.link_map_path = expanded[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-Map=")) {
            parsed.link_map_path = arg["-Map=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--Map=")) {
            parsed.link_map_path = arg["--Map=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--map=")) {
            parsed.link_map_path = arg["--map=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--emit-manifest")) {
            index += 1;
            if (index >= expanded.len) return error.InvalidArguments;
            parsed.manifest_path = expanded[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--emit-manifest=")) {
            parsed.manifest_path = arg["--emit-manifest=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-fork")) continue;
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
        try input_paths.append(allocator, arg);
    }

    parsed.input_paths = try input_paths.toOwnedSlice(allocator);
    return parsed;
}

fn supportedIgnoredZPolicy(value: []const u8) bool {
    return std.mem.eql(u8, value, "relro") or
        std.mem.eql(u8, value, "now") or
        std.mem.eql(u8, value, "noexecstack") or
        std.mem.eql(u8, value, "execstack");
}

fn parseBuildIdMode(value: []const u8) !tldr.model.BuildIdMode {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "fast")) return .fast;
    if (std.mem.eql(u8, value, "sha1")) return .sha1;
    return error.InvalidArguments;
}

fn supportedStaticHashStyle(value: []const u8) bool {
    return std.mem.eql(u8, value, "gnu");
}

fn parseIcf(value: []const u8) !tldr.model.IcfMode {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "none")) return .off;
    return error.InvalidArguments;
}

fn parseIncrementalMode(value: []const u8) !tldr.model.IncrementalMode {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "prepare")) return .prepare;
    if (std.mem.eql(u8, value, "relink")) return .relink;
    return error.InvalidArguments;
}

fn expandArgs(allocator: Allocator, args: []const []const u8) ![]const []const u8 {
    var expanded: std.ArrayListUnmanaged([]const u8) = .empty;
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '@') {
            const bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), arg[1..], allocator, .limited(max_response_bytes));
            try appendResponseTokens(allocator, &expanded, bytes);
        } else {
            try expanded.append(allocator, arg);
        }
    }
    return try expanded.toOwnedSlice(allocator);
}

fn appendResponseTokens(
    allocator: Allocator,
    tokens: *std.ArrayListUnmanaged([]const u8),
    bytes: []const u8,
) !void {
    var index: usize = 0;
    while (true) {
        while (index < bytes.len and std.ascii.isWhitespace(bytes[index])) index += 1;
        if (index >= bytes.len) return;

        var token: std.ArrayListUnmanaged(u8) = .empty;
        while (index < bytes.len and !std.ascii.isWhitespace(bytes[index])) {
            const byte = bytes[index];
            if (byte == '"' or byte == '\'') {
                const quote = byte;
                index += 1;
                while (index < bytes.len and bytes[index] != quote) : (index += 1) {
                    if (bytes[index] == '\\' and index + 1 < bytes.len) index += 1;
                    try token.append(allocator, bytes[index]);
                }
                if (index >= bytes.len) return error.InvalidArguments;
                index += 1;
                continue;
            }
            if (byte == '\\' and index + 1 < bytes.len) {
                index += 1;
                try token.append(allocator, bytes[index]);
                index += 1;
                continue;
            }
            try token.append(allocator, byte);
            index += 1;
        }
        try tokens.append(allocator, try token.toOwnedSlice(allocator));
    }
}

test "response tokenizer preserves quoted tokens" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit(allocator);
    }

    try appendResponseTokens(allocator, &tokens, "-o \"linked image\" 'input object.o'");

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try std.testing.expectEqualStrings("-o", tokens.items[0]);
    try std.testing.expectEqualStrings("linked image", tokens.items[1]);
    try std.testing.expectEqualStrings("input object.o", tokens.items[2]);
}

test "usage renders through pretty plain and colored output" {
    const plain = try pretty_usage.renderUsageTextAlloc(std.testing.allocator, usage_text, .{ .layout = .{ .width = 120 } });
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    try std.testing.expect(std.mem.startsWith(u8, plain, "usage: tldr-link"));

    const colored = try pretty_usage.renderUsageTextAlloc(std.testing.allocator, usage_text, .{ .layout = .{ .width = 120, .color = .ansi } });
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "tldr-link") != null);
}

test "usage wraps long option list at terminal width" {
    const rendered = try pretty_usage.renderUsageTextAlloc(std.testing.allocator, usage_text, .{ .layout = .{ .width = 48 } });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n  ") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[-L PATH]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[--gc-sections]") != null);
}

test "command errors render through pretty plain and colored output" {
    const plain = try pretty_usage.renderErrorTextAlloc(std.testing.allocator, "tldr-link", "OutOfMemory", .{ .layout = .{ .width = 88 } });
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("tldr-link: OutOfMemory\n", plain);

    const colored = try pretty_usage.renderErrorTextAlloc(std.testing.allocator, "tldr-link", "OutOfMemory", .{ .layout = .{ .width = 88, .color = .ansi } });
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "OutOfMemory") != null);
}

test "link failures render through pretty plain and colored output" {
    var diagnostics: tldr.Diagnostics = .{};
    diagnostics.recordUndefinedSymbol("tiny.o", "__tiny_make_integer");
    diagnostics.recordUndefinedSymbol("libtinyrt.a", "memcpy");

    const plain = try renderLinkFailureAlloc(
        std.testing.allocator,
        .{ .width = 120 },
        diagnostics.linkFailure(error.UndefinedSymbol),
    );
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings(
        \\TLDR link failed: undefined symbols
        \\  __tiny_make_integer referenced by tiny.o
        \\  memcpy referenced by libtinyrt.a
        \\
    , plain);

    const colored = try renderLinkFailureAlloc(
        std.testing.allocator,
        .{ .width = 120, .color = .ansi },
        diagnostics.linkFailure(error.UndefinedSymbol),
    );
    defer std.testing.allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "undefined symbols") != null);
}

test "link failure details wrap at terminal width" {
    var diagnostics: tldr.Diagnostics = .{};
    diagnostics.recordUnsupportedArchiveMemberFormat("libmixed.a", "needed.obj", .coff, .elf);

    const rendered = try renderLinkFailureAlloc(
        std.testing.allocator,
        .{ .width = 48 },
        diagnostics.linkFailure(error.UnsupportedFormat),
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "TLDR link failed:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "unsupported input format") != null);
}

test "CLI input loader maps file bytes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(sys.fs.debugIo(), .{
        .sub_path = "input.o",
        .data = "mapped object",
    });
    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "input.o" });
    defer allocator.free(object_path);

    var loaded = try loadInputs(allocator, &.{object_path});
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), loaded.inputs.items.len);
    try std.testing.expectEqualStrings("mapped object", loaded.inputs.items[0].bytes);
    try std.testing.expect(loaded.files.items[0].mapping != null);
}

test "CLI input loader reuses duplicate archive paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(sys.fs.debugIo(), .{
        .sub_path = "libinput.a",
        .data = "mapped archive",
    });
    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const archive_path = try std.fs.path.join(allocator, &.{ root, "libinput.a" });
    defer allocator.free(archive_path);

    var loaded = try loadInputs(allocator, &.{ archive_path, archive_path });
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), loaded.inputs.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.files.items.len);
    try std.testing.expectEqual(loaded.inputs.items[0].bytes.ptr, loaded.inputs.items[1].bytes.ptr);
}

test "CLI input prefault threshold protects small links" {
    try std.testing.expect(!prefaultInputs(prefault_input_threshold - 1));
    if (sys.thread.threadsSupported()) {
        try std.testing.expect(prefaultInputs(prefault_input_threshold));
    }
}

test "CLI input prefault touches mapped bytes" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, sys.memory.pageSize() * 2 + 1);
    defer allocator.free(bytes);
    @memset(bytes, 0x5a);

    var loaded: LoadedInputs = .{};
    defer loaded.files.deinit(allocator);
    try loaded.files.append(allocator, .{ .bytes = bytes });
    prefaultMappedInputs(&loaded);
}

test "CLI executable output writer sets executable permissions" {
    if (comptime !sys.fs.FilePermissions.has_executable_bit) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);

    try writeExecutableFile(sys.fs.cwd(), output_path, std.elf.MAGIC);

    const stat = try sys.fs.statFile(output_path);
    try std.testing.expect((stat.permissions.toMode() & 0o111) != 0);
}

test "CLI links a response-file ELF object" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const response_path = try std.fs.path.join(allocator, &.{ root, "response.txt" });
    defer allocator.free(response_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);

    const text = [_]u8{
        0xb8, 0x3c, 0x00, 0x00, 0x00,
        0x31, 0xff, 0x0f, 0x05,
    };
    const object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);

    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = object });
    const response = try std.fmt.allocPrint(allocator, "-o {s} -e _start {s}\n", .{ output_path, object_path });
    defer allocator.free(response);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = response_path, .data = response });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const response_arg = try std.fmt.allocPrint(allocator, "@{s}", .{response_path});
    defer allocator.free(response_arg);
    const code = try run(allocator, &.{response_arg}, &stderr, .{ .width = 88 });
    try std.testing.expectEqual(@as(u8, 0), code);

    const linked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(linked);
    try std.testing.expectEqualSlices(u8, std.elf.MAGIC, linked[0..4]);
    try std.testing.expectEqual(@as(u64, text.len), try linkedSectionSize(linked, ".text"));
}

fn expectNoOutputLitter(allocator: Allocator, root: []const u8) !void {
    const entries = try sys.fs.listDirAlloc(allocator, root);
    defer {
        for (entries) |entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    for (entries) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tldr-tmp-") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tldr-old-") == null);
    }
}

test "CLI relinking over an existing output leaves no litter" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);

    const text = [_]u8{
        0xb8, 0x3c, 0x00, 0x00, 0x00,
        0x31, 0xff, 0x0f, 0x05,
    };
    const object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const args = [_][]const u8{ "-o", output_path, "-e", "_start", object_path };
    try std.testing.expectEqual(@as(u8, 0), try run(allocator, &args, &stderr, .{ .width = 88 }));
    try std.testing.expectEqual(@as(u8, 0), try run(allocator, &args, &stderr, .{ .width = 88 }));

    const linked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(linked);
    try std.testing.expectEqualSlices(u8, std.elf.MAGIC, linked[0..4]);
    try expectNoOutputLitter(allocator, root);
}

test "CLI failed links preserve the previous output" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const broken_path = try std.fs.path.join(allocator, &.{ root, "broken.o" });
    defer allocator.free(broken_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);

    const text = [_]u8{
        0xb8, 0x3c, 0x00, 0x00, 0x00,
        0x31, 0xff, 0x0f, 0x05,
    };
    const object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = object });

    const call = [_]u8{ 0xe8, 0, 0, 0, 0, 0xc3 };
    const broken_object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &call, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, call.len),
            elf_object.Symbol.undefinedFunction("missing"),
        },
        .relocations = &.{elf_object.Relocation.x86_64(1, 1, 3, .PLT32, -4)},
    });
    defer allocator.free(broken_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = broken_path, .data = broken_object });

    var stderr_buffer: [2048]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const good_args = [_][]const u8{ "-o", output_path, "-e", "_start", object_path };
    try std.testing.expectEqual(@as(u8, 0), try run(allocator, &good_args, &stderr, .{ .width = 88 }));
    const before = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(before);

    const broken_args = [_][]const u8{ "-o", output_path, "-e", "_start", broken_path };
    try std.testing.expectEqual(@as(u8, 1), try run(allocator, &broken_args, &stderr, .{ .width = 88 }));

    const after = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try expectNoOutputLitter(allocator, root);
}

test "CLI accepts strip-debug for DWARF payloads" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "debug.o" });
    defer allocator.free(object_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);

    const text = [_]u8{0xc3};
    const debug = [_]u8{ 1, 2, 3, 4 };
    const object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16),
            elf_object.Section.nonAlloc(".debug_info", &debug, std.elf.SHT_PROGBITS, 1),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.section(2),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);

    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const code = try run(allocator, &.{ "--strip-debug", "-o", output_path, object_path }, &stderr, .{ .width = 88 });
    try std.testing.expectEqual(@as(u8, 0), code);

    const linked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(linked);
    try std.testing.expectEqualSlices(u8, std.elf.MAGIC, linked[0..4]);
    try std.testing.expectError(error.MissingSection, linkedSectionSize(linked, ".debug_info"));
}

test "CLI resolves static library search inputs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const library_dir = try std.fs.path.join(allocator, &.{ root, "lib" });
    defer allocator.free(library_dir);
    const library_path = try std.fs.path.join(allocator, &.{ library_dir, "libtiny.a" });
    defer allocator.free(library_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);

    try sys.fs.createDirPath(library_dir);

    const text = [_]u8{
        0xb8, 0x3c, 0x00, 0x00, 0x00,
        0x31, 0xff, 0x0f, 0x05,
    };
    const object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = library_path, .data = object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const search_arg = try std.fmt.allocPrint(allocator, "-L{s}", .{library_dir});
    defer allocator.free(search_arg);
    const code = try run(
        allocator,
        &.{
            "-m",
            "elf_x86_64",
            "--as-needed",
            "-static",
            "--build-id",
            "--hash-style=gnu",
            "-z",
            "relro",
            "--start-group",
            search_arg,
            "-ltiny",
            "--end-group",
            "-o",
            output_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), code);

    const linked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(linked);
    try std.testing.expectEqualSlices(u8, std.elf.MAGIC, linked[0..4]);
    try std.testing.expectEqual(@as(u64, text.len), try linkedSectionSize(linked, ".text"));
    try std.testing.expectEqual(@as(u64, 24), try linkedSectionSize(linked, ".note.gnu.build-id"));
}

test "CLI expands static linker script group inputs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const library_dir = try std.fs.path.join(allocator, &.{ root, "lib" });
    defer allocator.free(library_dir);
    const object_path = try std.fs.path.join(allocator, &.{ library_dir, "tiny.o" });
    defer allocator.free(object_path);
    const script_path = try std.fs.path.join(allocator, &.{ library_dir, "libtiny.a" });
    defer allocator.free(script_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);

    try sys.fs.createDirPath(library_dir);

    const text = [_]u8{
        0xb8, 0x3c, 0x00, 0x00, 0x00,
        0x31, 0xff, 0x0f, 0x05,
    };
    const object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = object });

    const script = try std.fmt.allocPrint(
        allocator,
        "/* GNU ld script */\nOUTPUT_FORMAT(elf64-x86-64)\nGROUP ( tiny.o )\n",
        .{},
    );
    defer allocator.free(script);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = script_path, .data = script });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const search_arg = try std.fmt.allocPrint(allocator, "-L{s}", .{library_dir});
    defer allocator.free(search_arg);
    const code = try run(
        allocator,
        &.{
            "-static",
            search_arg,
            "-ltiny",
            "-o",
            output_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), code);

    const linked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(linked);
    try std.testing.expectEqualSlices(u8, std.elf.MAGIC, linked[0..4]);
    try std.testing.expectEqual(@as(u64, text.len), try linkedSectionSize(linked, ".text"));
}

test "CLI parses incremental preparation mode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const compact = try parseArgs(allocator, &.{"input.o"});
    try std.testing.expectEqual(tldr.model.IncrementalMode.off, compact.incremental_mode);

    const prepared = try parseArgs(allocator, &.{ "--incremental=prepare", "input.o" });
    try std.testing.expectEqual(tldr.model.IncrementalMode.prepare, prepared.incremental_mode);

    const stripped = try parseArgs(allocator, &.{ "--strip-debug", "input.o" });
    try std.testing.expect(stripped.strip_debug);

    const relink = try parseArgs(allocator, &.{ "--incremental=relink", "--incremental-manifest=linked.manifest", "input.o" });
    try std.testing.expectEqual(tldr.model.IncrementalMode.relink, relink.incremental_mode);
    try std.testing.expectEqualStrings("linked.manifest", relink.incremental_manifest_path.?);

    const link_map = try parseArgs(allocator, &.{ "--emit-link-map=linked.map", "input.o" });
    try std.testing.expectEqualStrings("linked.map", link_map.link_map_path.?);

    const gnu_link_map = try parseArgs(allocator, &.{ "-Map=linked.gnu.map", "input.o" });
    try std.testing.expectEqualStrings("linked.gnu.map", gnu_link_map.link_map_path.?);

    const gnu_link_map_separate = try parseArgs(allocator, &.{ "-Map", "linked.gnu.separate.map", "input.o" });
    try std.testing.expectEqualStrings("linked.gnu.separate.map", gnu_link_map_separate.link_map_path.?);

    const long_gnu_link_map = try parseArgs(allocator, &.{ "--Map=linked.long.map", "input.o" });
    try std.testing.expectEqualStrings("linked.long.map", long_gnu_link_map.link_map_path.?);

    const manifest = try parseArgs(allocator, &.{ "--emit-manifest=linked.manifest", "input.o" });
    try std.testing.expectEqualStrings("linked.manifest", manifest.manifest_path.?);
}

test "CLI accepts static output metadata policy flags narrowly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const build_id = try parseArgs(allocator, &.{ "--build-id", "input.o" });
    try std.testing.expectEqual(tldr.model.BuildIdMode.fast, build_id.build_id);

    const build_id_sha1 = try parseArgs(allocator, &.{ "--build-id=sha1", "input.o" });
    try std.testing.expectEqual(tldr.model.BuildIdMode.sha1, build_id_sha1.build_id);

    const build_id_fast = try parseArgs(allocator, &.{ "--build-id=fast", "--hash-style=gnu", "input.o" });
    try std.testing.expectEqual(tldr.model.BuildIdMode.fast, build_id_fast.build_id);

    const build_id_none = try parseArgs(allocator, &.{ "--build-id=none", "input.o" });
    try std.testing.expectEqual(tldr.model.BuildIdMode.none, build_id_none.build_id);

    try std.testing.expectError(error.InvalidArguments, parseArgs(allocator, &.{ "--build-id=uuid", "input.o" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(allocator, &.{ "--hash-style=both", "input.o" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(allocator, &.{ "--hash-style", "sysv", "input.o" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(allocator, &.{ "-z", "max-page-size=0x10000", "input.o" }));
}

test "CLI parses dynamic output policy flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const parsed = try parseArgs(allocator, &.{ "--eh-frame-hdr", "-pie", "-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "--export-dynamic", "-soname=libtiny.so", "input.o" });
    try std.testing.expect(parsed.eh_frame_header);
    try std.testing.expect(parsed.pie);
    try std.testing.expectEqualStrings("/lib64/ld-linux-x86-64.so.2", parsed.dynamic_linker.?);
    try std.testing.expect(parsed.export_dynamic);
    try std.testing.expectEqualStrings("libtiny.so", parsed.soname.?);
    try std.testing.expectEqual(tldr.model.OutputKind.executable, parsed.output_kind);

    const shared = try parseArgs(allocator, &.{ "--shared", "--dynamic-linker=/lib64/ld-linux-x86-64.so.2", "input.o" });
    try std.testing.expectEqual(tldr.model.OutputKind.shared_library, shared.output_kind);
    try std.testing.expectEqualStrings("/lib64/ld-linux-x86-64.so.2", shared.dynamic_linker.?);

    try std.testing.expectError(error.InvalidArguments, parseArgs(allocator, &.{"-dynamic-linker"}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(allocator, &.{ "--dynamic-linker", "" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(allocator, &.{ "-soname=", "input.o" }));
}

test "CLI reports dynamic output as linker failure" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);

    const text = [_]u8{0xc3};
    const object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const code = try run(allocator, &.{ "-pie", "-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "-o", output_path, object_path }, &stderr, .{ .width = 88 });
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "UnsupportedDynamicLinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "usage: tldr-link") == null);
}

test "CLI emits prepared manifest link map" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const link_map_path = try std.fs.path.join(allocator, &.{ root, "linked.map" });
    defer allocator.free(link_map_path);
    const link_map_arg = try std.fmt.allocPrint(allocator, "-Map={s}", .{link_map_path});
    defer allocator.free(link_map_arg);

    const text = [_]u8{0xc3};
    const object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);

    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            link_map_arg,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), code);

    const link_map = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), link_map_path, allocator, .limited(4096));
    defer allocator.free(link_map);
    try std.testing.expect(std.mem.indexOf(u8, link_map, "tldr link map\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, link_map, "hash=0x") != null);
    try std.testing.expect(std.mem.indexOf(u8, link_map, "contributions (1):") != null);
}

test "CLI emits prepared private manifest" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const text = [_]u8{0xc3};
    const object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);

    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            "--emit-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), code);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer parsed_manifest.deinit(allocator);

    try std.testing.expect(parsed_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{.{ .name = object_path, .bytes = object }},
    ));
    try std.testing.expectEqual(@as(usize, 1), parsed_manifest.contributions.len);
}

test "CLI relinks build id output from prepared private manifest" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const old_text = [_]u8{0xc3};
    const old_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text", &old_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, old_text.len),
        },
    });
    defer allocator.free(old_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = old_object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            "--build-id",
            "--emit-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);

    const new_text = [_]u8{ 0x90, 0xc3 };
    const new_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text", &new_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, new_text.len),
        },
    });
    defer allocator.free(new_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = new_object });

    var candidate = try tldr.link(
        allocator,
        &.{.{ .name = object_path, .bytes = new_object }},
        .{ .entry_symbol = "_start", .incremental_mode = .relink, .build_id = .fast },
    );
    defer candidate.deinit(allocator);

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{
            "--incremental=relink",
            "--build-id",
            "--incremental-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const relinked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(relinked);
    try std.testing.expectEqualSlices(u8, candidate.bytes, relinked);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer parsed_manifest.deinit(allocator);

    try std.testing.expect(parsed_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink, .build_id = .fast },
        &.{.{ .name = object_path, .bytes = new_object }},
    ));
}

test "CLI relinks from prepared private manifest" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const old_text = [_]u8{0xc3};
    const old_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text", &old_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, old_text.len),
        },
    });
    defer allocator.free(old_object);

    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = old_object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            "--emit-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);

    const new_text = [_]u8{ 0x90, 0xc3 };
    const new_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text", &new_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, new_text.len),
        },
    });
    defer allocator.free(new_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = new_object });

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{
            "--incremental=relink",
            "--incremental-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const relinked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(relinked);
    try std.testing.expect(std.mem.indexOf(u8, relinked, &new_text) != null);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer parsed_manifest.deinit(allocator);

    try std.testing.expect(parsed_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{.{ .name = object_path, .bytes = new_object }},
    ));
    try std.testing.expectEqual(@as(u64, new_text.len), parsed_manifest.contributions[0].size);
}

test "CLI relink full-links over a stale manifest protocol" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const start_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(start_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const start_text = [_]u8{0xc3};
    const start_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, start_text.len),
        },
    });
    defer allocator.free(start_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = start_path, .data = start_object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{ "--incremental=prepare", "--emit-manifest", manifest_path, "-o", output_path, "-e", "_start", start_path },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(1 << 20));
    defer allocator.free(manifest_bytes);
    const protocol_index = std.mem.indexOf(u8, manifest_bytes, tldr.incremental.manifest_binary_protocol) orelse
        return error.MissingManifestProtocol;
    const stale_bytes = try allocator.dupe(u8, manifest_bytes);
    defer allocator.free(stale_bytes);
    stale_bytes[protocol_index + tldr.incremental.manifest_binary_protocol.len - 1] = '0';
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = manifest_path, .data = stale_bytes, .flags = .{ .truncate = true } });

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{ "--incremental=relink", "--incremental-manifest", manifest_path, "-o", output_path, "-e", "_start", start_path },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const healed_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(1 << 20));
    defer allocator.free(healed_bytes);
    var healed = try tldr.incremental.Manifest.fromBinary(allocator, healed_bytes);
    defer healed.deinit(allocator);
    try std.testing.expect(healed.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{.{ .name = start_path, .bytes = start_object }},
    ));
}

test "CLI relink full-links over duplicate manifest contributions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const start_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(start_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const start_text = [_]u8{ 0xc3, 0x90, 0x90 };
    const start_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, start_text.len),
        },
    });
    defer allocator.free(start_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = start_path, .data = start_object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{ "--incremental=prepare", "--emit-manifest", manifest_path, "-o", output_path, "-e", "_start", start_path },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(1 << 20));
    defer allocator.free(manifest_bytes);
    var duplicated = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer duplicated.deinit(allocator);
    try std.testing.expect(duplicated.contributions.len != 0);
    const previous_contributions = duplicated.contributions;
    const contributions = try allocator.alloc(tldr.incremental.ContributionRecord, previous_contributions.len + 1);
    @memcpy(contributions[0..previous_contributions.len], previous_contributions);
    contributions[previous_contributions.len] = previous_contributions[0];
    duplicated.contributions = contributions;
    duplicated.owned.contributions = true;
    const duplicated_bytes = try duplicated.formatBinaryAlloc(allocator);
    defer allocator.free(duplicated_bytes);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = manifest_path, .data = duplicated_bytes, .flags = .{ .truncate = true } });

    const changed_text = [_]u8{ 0xc3, 0x90, 0xcc };
    const changed_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text.start", &changed_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, changed_text.len),
        },
    });
    defer allocator.free(changed_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = start_path, .data = changed_object, .flags = .{ .truncate = true } });

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{ "--incremental=relink", "--incremental-manifest", manifest_path, "-o", output_path, "-e", "_start", start_path },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const healed_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(1 << 20));
    defer allocator.free(healed_bytes);
    var healed = try tldr.incremental.Manifest.fromBinary(allocator, healed_bytes);
    defer healed.deinit(allocator);
    var healed_state = try tldr.incremental.PreparedState.fromOwnedManifest(allocator, healed.take());
    defer healed_state.deinit(allocator);
    try healed_state.ensureReplacementIndex(allocator, &.{.{
        .input_name = start_path,
        .input_index = 0,
        .kind = .section,
        .name = ".text.start",
        .ordinal = 0,
        .size = changed_text.len,
        .alignment = 16,
    }});
    try std.testing.expect(healed_state.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{.{ .name = start_path, .bytes = changed_object }},
    ));
}

test "CLI relinks same-shape direct object payloads" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const start_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(start_path);
    const patch_path = try std.fs.path.join(allocator, &.{ root, "patch.o" });
    defer allocator.free(patch_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const start_text = [_]u8{0xc3};
    const start_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, start_text.len),
        },
    });
    defer allocator.free(start_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = start_path, .data = start_object });

    const old_patch = "old!";
    const old_patch_object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".rodata.patch", old_patch, 0, 4)},
        .symbols = &.{elf_object.Symbol.section(1)},
    });
    defer allocator.free(old_patch_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = patch_path, .data = old_patch_object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            "--emit-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            start_path,
            patch_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);

    const new_patch = "new!";
    const new_patch_object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".rodata.patch", new_patch, 0, 4)},
        .symbols = &.{elf_object.Symbol.section(1)},
    });
    defer allocator.free(new_patch_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = patch_path, .data = new_patch_object });

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{
            "--incremental=relink",
            "--incremental-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            start_path,
            patch_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const relinked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(relinked);
    try std.testing.expect(std.mem.indexOf(u8, relinked, new_patch) != null);
    try std.testing.expect(std.mem.indexOf(u8, relinked, old_patch) == null);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer parsed_manifest.deinit(allocator);

    try std.testing.expect(parsed_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{
            .{ .name = start_path, .bytes = start_object },
            .{ .name = patch_path, .bytes = new_patch_object },
        },
    ));
    try std.testing.expectEqual(tldr.incremental.hashBytes(new_patch_object), parsed_manifest.inputs[1].hash);
}

test "CLI relinks same-shape archive member payloads" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const start_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(start_path);
    const archive_path = try std.fs.path.join(allocator, &.{ root, "libpatch.a" });
    defer allocator.free(archive_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const start_text = [_]u8{0xc3};
    const ptr_bytes = @as([8]u8, @splat(0));
    const start_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
            elf_object.Section.progbits(".data.ptr", &ptr_bytes, std.elf.SHF_WRITE, 8),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.section(2),
            elf_object.Symbol.function("_start", 1, 0, start_text.len),
            elf_object.Symbol.undefinedObject("patch_data"),
        },
        .relocations = &.{elf_object.Relocation.x86_64(2, 0, 4, .@"64", 0)},
    });
    defer allocator.free(start_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = start_path, .data = start_object });

    const old_patch = "old!";
    const old_patch_object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".rodata.patch", old_patch, 0, 4)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.object("patch_data", 1, 0, old_patch.len),
        },
    });
    defer allocator.free(old_patch_object);
    const old_archive = try tldr.archive.build(allocator, &.{.{ .name = "patch.o", .bytes = old_patch_object, .symbols = &.{"patch_data"} }});
    defer allocator.free(old_archive);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = archive_path, .data = old_archive });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            "--emit-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            start_path,
            archive_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);

    const new_patch = "new!";
    const new_patch_object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".rodata.patch", new_patch, 0, 4)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.object("patch_data", 1, 0, new_patch.len),
        },
    });
    defer allocator.free(new_patch_object);
    const new_archive = try tldr.archive.build(allocator, &.{.{ .name = "patch.o", .bytes = new_patch_object, .symbols = &.{"patch_data"} }});
    defer allocator.free(new_archive);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = archive_path, .data = new_archive });

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{
            "--incremental=relink",
            "--incremental-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            start_path,
            archive_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const relinked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(relinked);
    try std.testing.expect(std.mem.indexOf(u8, relinked, new_patch) != null);
    try std.testing.expect(std.mem.indexOf(u8, relinked, old_patch) == null);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer parsed_manifest.deinit(allocator);

    try std.testing.expect(parsed_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{
            .{ .name = start_path, .bytes = start_object },
            .{ .name = archive_path, .bytes = new_archive },
        },
    ));
    try std.testing.expectEqual(tldr.incremental.hashBytes(new_archive), parsed_manifest.inputs[1].hash);
    try std.testing.expectEqual(@as(usize, 1), parsed_manifest.archive_members.len);
    try std.testing.expectEqual(tldr.incremental.hashBytes(new_patch_object), parsed_manifest.archive_members[0].hash);

    const third_patch = "two!";
    const third_patch_object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".rodata.patch", third_patch, 0, 4)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.object("patch_data", 1, 0, third_patch.len),
        },
    });
    defer allocator.free(third_patch_object);
    const third_archive = try tldr.archive.build(allocator, &.{.{ .name = "patch.o", .bytes = third_patch_object, .symbols = &.{"patch_data"} }});
    defer allocator.free(third_archive);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = archive_path, .data = third_archive });

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const second_relink_code = try run(
        allocator,
        &.{
            "--incremental=relink",
            "--incremental-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            start_path,
            archive_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), second_relink_code);

    const second_relinked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(second_relinked);
    try std.testing.expect(std.mem.indexOf(u8, second_relinked, third_patch) != null);
    try std.testing.expect(std.mem.indexOf(u8, second_relinked, new_patch) == null);

    const second_manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(second_manifest_bytes);
    var second_manifest = try tldr.incremental.Manifest.fromBinary(allocator, second_manifest_bytes);
    defer second_manifest.deinit(allocator);

    try std.testing.expect(second_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{
            .{ .name = start_path, .bytes = start_object },
            .{ .name = archive_path, .bytes = third_archive },
        },
    ));
    try std.testing.expectEqual(tldr.incremental.hashBytes(third_archive), second_manifest.inputs[1].hash);
    try std.testing.expectEqual(tldr.incremental.hashBytes(third_patch_object), second_manifest.archive_members[0].hash);
}

test "CLI relink full-links when changed input gains contribution" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const start_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(start_path);
    const feature_path = try std.fs.path.join(allocator, &.{ root, "feature.o" });
    defer allocator.free(feature_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const start_text = [_]u8{0xc3};
    const start_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text", &start_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, start_text.len),
        },
    });
    defer allocator.free(start_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = start_path, .data = start_object });

    const old_feature_object = try elf_object.build(allocator, .{ .sections = &.{} });
    defer allocator.free(old_feature_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = feature_path, .data = old_feature_object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            "--emit-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            start_path,
            feature_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);

    const feature_text = [_]u8{0x90};
    const new_feature_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text.feature", &feature_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("feature", 1, 0, feature_text.len),
        },
    });
    defer allocator.free(new_feature_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = feature_path, .data = new_feature_object });

    var candidate = try tldr.link(
        allocator,
        &.{
            .{ .name = start_path, .bytes = start_object },
            .{ .name = feature_path, .bytes = new_feature_object },
        },
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
    );
    defer candidate.deinit(allocator);

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{
            "--incremental=relink",
            "--incremental-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            start_path,
            feature_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const relinked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(relinked);
    try std.testing.expectEqualSlices(u8, candidate.bytes, relinked);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer parsed_manifest.deinit(allocator);

    try std.testing.expect(parsed_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{
            .{ .name = start_path, .bytes = start_object },
            .{ .name = feature_path, .bytes = new_feature_object },
        },
    ));
    try std.testing.expectEqual(@as(usize, 2), parsed_manifest.contributions.len);
}

test "CLI relink reuses unchanged output without rewriting" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);
    const link_map_path = try std.fs.path.join(allocator, &.{ root, "linked.map" });
    defer allocator.free(link_map_path);

    const text = [_]u8{0xc3};
    const object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(object);

    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            "--emit-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);

    const sentinel = "cached-output-sentinel";
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = output_path, .data = sentinel });

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{
            "--incremental=relink",
            "--incremental-manifest",
            manifest_path,
            "--emit-link-map",
            link_map_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const relinked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(relinked);
    try std.testing.expectEqualSlices(u8, sentinel, relinked);

    const link_map = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), link_map_path, allocator, .limited(4096));
    defer allocator.free(link_map);
    try std.testing.expect(std.mem.indexOf(u8, link_map, "summary: inputs=1 sections=1") != null);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer parsed_manifest.deinit(allocator);

    try std.testing.expect(parsed_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{.{ .name = object_path, .bytes = object }},
    ));
}

test "CLI relink full-links reordered inputs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const start_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(start_path);
    const helper_path = try std.fs.path.join(allocator, &.{ root, "helper.o" });
    defer allocator.free(helper_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const start_text = [_]u8{0xc3};
    const start_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text.start", &start_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, start_text.len),
        },
    });
    defer allocator.free(start_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = start_path, .data = start_object });

    const helper_text = [_]u8{ 0x90, 0xc3 };
    const helper_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text.helper", &helper_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("helper", 1, 0, helper_text.len),
        },
    });
    defer allocator.free(helper_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = helper_path, .data = helper_object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            "--emit-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            start_path,
            helper_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);

    const sentinel = "stale-reordered-output";
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = output_path, .data = sentinel });

    var candidate = try tldr.link(
        allocator,
        &.{
            .{ .name = helper_path, .bytes = helper_object },
            .{ .name = start_path, .bytes = start_object },
        },
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
    );
    defer candidate.deinit(allocator);

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{
            "--incremental=relink",
            "--incremental-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            helper_path,
            start_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const relinked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(relinked);
    try std.testing.expectEqualSlices(u8, candidate.bytes, relinked);
    try std.testing.expect(std.mem.indexOf(u8, relinked, sentinel) == null);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer parsed_manifest.deinit(allocator);

    try std.testing.expect(parsed_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{
            .{ .name = helper_path, .bytes = helper_object },
            .{ .name = start_path, .bytes = start_object },
        },
    ));
}

test "CLI relink full-link fallback does not require previous output" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const extra_path = try std.fs.path.join(allocator, &.{ root, "extra.o" });
    defer allocator.free(extra_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const start_text = [_]u8{0xc3};
    const start_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text", &start_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, start_text.len),
        },
    });
    defer allocator.free(start_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = start_object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            "--emit-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);
    try sys.fs.cwd().deleteFile(sys.fs.debugIo(), output_path);

    const extra_text = [_]u8{ 0x90, 0xc3 };
    const extra_object = try elf_object.build(allocator, .{
        .sections = &.{
            elf_object.Section.progbits(".text.extra", &extra_text, std.elf.SHF_EXECINSTR, 16),
        },
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("extra", 1, 0, extra_text.len),
        },
    });
    defer allocator.free(extra_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = extra_path, .data = extra_object });

    var candidate = try tldr.link(
        allocator,
        &.{
            .{ .name = object_path, .bytes = start_object },
            .{ .name = extra_path, .bytes = extra_object },
        },
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
    );
    defer candidate.deinit(allocator);

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{
            "--incremental=relink",
            "--incremental-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
            extra_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const relinked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(relinked);
    try std.testing.expectEqualSlices(u8, candidate.bytes, relinked);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer parsed_manifest.deinit(allocator);

    try std.testing.expect(parsed_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{
            .{ .name = object_path, .bytes = start_object },
            .{ .name = extra_path, .bytes = extra_object },
        },
    ));
}

test "CLI relink falls back when candidate metadata layout changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "start.o" });
    defer allocator.free(object_path);
    const output_path = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(output_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "linked.manifest" });
    defer allocator.free(manifest_path);

    const text = [_]u8{0xc3};
    const old_object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
        },
    });
    defer allocator.free(old_object);

    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = old_object });

    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const prepare_code = try run(
        allocator,
        &.{
            "--incremental=prepare",
            "--emit-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), prepare_code);

    const new_object = try elf_object.build(allocator, .{
        .sections = &.{elf_object.Section.progbits(".text", &text, std.elf.SHF_EXECINSTR, 16)},
        .symbols = &.{
            elf_object.Symbol.section(1),
            elf_object.Symbol.function("_start", 1, 0, text.len),
            elf_object.Symbol.function("__tldr_incremental_metadata_growth_probe", 1, 0, 0),
        },
    });
    defer allocator.free(new_object);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = object_path, .data = new_object });

    var candidate = try tldr.link(
        allocator,
        &.{.{ .name = object_path, .bytes = new_object }},
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
    );
    defer candidate.deinit(allocator);

    stderr = std.Io.Writer.fixed(&stderr_buffer);
    const relink_code = try run(
        allocator,
        &.{
            "--incremental=relink",
            "--incremental-manifest",
            manifest_path,
            "-o",
            output_path,
            "-e",
            "_start",
            object_path,
        },
        &stderr,
        .{ .width = 88 },
    );
    try std.testing.expectEqual(@as(u8, 0), relink_code);

    const relinked = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), output_path, allocator, .limited(4096));
    defer allocator.free(relinked);
    try std.testing.expectEqualSlices(u8, candidate.bytes, relinked);

    const manifest_bytes = try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), manifest_path, allocator, .limited(4096));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try tldr.incremental.Manifest.fromBinary(allocator, manifest_bytes);
    defer parsed_manifest.deinit(allocator);

    try std.testing.expect(parsed_manifest.canReuseFor(
        .{ .entry_symbol = "_start", .incremental_mode = .relink },
        &.{.{ .name = object_path, .bytes = new_object }},
    ));
}

test "candidate replacement extraction covers changed in-place plans" {
    try std.testing.expect(relinkNeedsCandidateReplacements(
        .{ .decision = .full_link, .blocker = .replacement_missing },
        .{ .summary = .{ .changed = 1 } },
    ));
    try std.testing.expect(relinkNeedsCandidateReplacements(
        .{ .decision = .in_place },
        .{ .summary = .{ .changed = 1 } },
    ));
    try std.testing.expect(!relinkNeedsCandidateReplacements(
        .{ .decision = .reuse_output },
        .{ .summary = .{ .unchanged = 1 } },
    ));
    try std.testing.expect(!relinkNeedsCandidateReplacements(
        .{ .decision = .full_link, .blocker = .input_added },
        .{ .summary = .{ .added = 1 } },
    ));
}

fn linkedSectionSize(image: []const u8, target_name: []const u8) !u64 {
    if (image.len < 64 or !std.mem.eql(u8, image[0..4], std.elf.MAGIC)) return error.InvalidElfHeader;
    const shoff = readElfU64(image, 40);
    const shentsize = readElfU16(image, 58);
    const shnum = readElfU16(image, 60);
    const shstrndx = readElfU16(image, 62);
    if (shentsize < 64 or shnum == 0 or shstrndx >= shnum) return error.InvalidElfHeader;

    const shstr_start = try sectionHeaderStart(image, shoff, shentsize, shstrndx);
    const shstr_offset = readElfU64(image, shstr_start + 24);
    const shstr_size = readElfU64(image, shstr_start + 32);
    if (shstr_offset > image.len or shstr_offset + shstr_size > image.len) return error.InvalidElfHeader;
    const shstrtab = image[@intCast(shstr_offset)..@intCast(shstr_offset + shstr_size)];

    var section_index: u16 = 0;
    while (section_index < shnum) : (section_index += 1) {
        const section_start = try sectionHeaderStart(image, shoff, shentsize, section_index);
        const name = try linkedSectionName(shstrtab, readElfU32(image, section_start));
        if (std.mem.eql(u8, name, target_name)) return readElfU64(image, section_start + 32);
    }
    return error.MissingSection;
}

fn linkedSectionName(shstrtab: []const u8, offset: u32) ![]const u8 {
    const start: usize = @intCast(offset);
    if (start >= shstrtab.len) return error.InvalidElfHeader;
    const end_offset = std.mem.indexOfScalar(u8, shstrtab[start..], 0) orelse return error.InvalidElfHeader;
    return shstrtab[start .. start + end_offset];
}

fn sectionHeaderStart(image: []const u8, shoff: u64, shentsize: u16, index: u16) !usize {
    const start = shoff + @as(u64, shentsize) * @as(u64, index);
    if (start > image.len or start + 64 > image.len) return error.InvalidElfHeader;
    return @intCast(start);
}

fn readElfU16(image: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, image[offset..][0..2], .little);
}

fn readElfU32(image: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, image[offset..][0..4], .little);
}

fn readElfU64(image: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, image[offset..][0..8], .little);
}
