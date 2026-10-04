const std = @import("std");
const gpu = @import("gpu");
const accy = @import("accy");
const pretty = @import("pretty");
const sys = @import("sys");
const ptx = @import("accy_validation_ptx");
const conformance = @import("root.zig");

const cases = conformance.cases;
const harness = conformance.harness;
const records = conformance.records;

const BackendChoice = enum {
    cuda,
    metal,
    vulkan,
};

pub fn main(init: sys.process.Init) !void {
    sys.env.installProcessEnvironment(init.minimal.environ);

    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = sys.stdio.stdout().writer(sys.stdio.debugIo(), &stdout_buffer);
    const writer = &stdout_writer.interface;
    defer writer.flush() catch {};

    const backend = try requestedBackend();
    switch (backend) {
        .cuda => try runCuda(allocator, writer),
        .metal => try runMetal(allocator, writer),
        .vulkan => try runVulkan(allocator, writer),
    }
}

fn runCuda(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    const ptxas_target = try ptx.assemble.probeTarget(allocator);
    const assemble_only = forcedAssembleMode();

    var cuda_state: ?harness.CudaState = if (assemble_only)
        null
    else
        harness.CudaState.initDevice(allocator, 0) catch |err| switch (err) {
            error.RuntimeUnavailable => null,
            else => return err,
        };
    defer if (cuda_state) |*state| state.deinit();

    if (cuda_state == null and ptxas_target == null) {
        try writeJsonLine(
            writer,
            records.Skip{ .reason = "cuda runtime and ptxas unavailable", .backend = "cuda" },
        );
        return;
    }

    const scratch: ?[]u8 = if (ptxas_target != null)
        try ptx.assemble.scratchDir(allocator)
    else
        null;
    defer if (scratch) |dir| ptx.assemble.removeScratchDir(allocator, dir);

    const assembler: ?harness.Assembler = if (ptxas_target) |target_name| .{
        .dir = scratch.?,
        .target = target_name,
    } else null;

    var emission_state = ptx.backend.State.init(allocator);
    const mode: harness.Mode = if (cuda_state != null) .execute else .assemble;
    const handle = if (cuda_state) |*state| state.handle() else emission_state.handle();
    const gate = harness.Gate{ .mode = mode, .assembler = assembler };

    try runAllCases(allocator, writer, "cuda", handle, gate);
}

fn runMetal(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    if (!accy.validation.gating.enabledByBuildOptions(.metal)) {
        try writeJsonLine(
            writer,
            records.Skip{ .reason = "metal build flag disabled", .backend = "metal" },
        );
        return;
    }
    if (!accy.validation.gating.appleMetalPlatform()) {
        try writeJsonLine(
            writer,
            records.Skip{ .reason = "unsupported platform", .backend = "metal" },
        );
        return;
    }

    var state = harness.MetalState.initDevice(allocator) catch |err| switch (err) {
        error.RuntimeUnavailable => {
            try writeJsonLine(
                writer,
                records.Skip{ .reason = "metal runtime unavailable", .backend = "metal" },
            );
            return;
        },
        else => return err,
    };
    defer state.deinit();

    try runAllCases(
        allocator,
        writer,
        "metal",
        state.handle(),
        .{ .mode = .execute, .assembler = null },
    );
}

/// Runs on device 0 of whichever Vulkan loader the process opens. On Linux a vendor driver, such
/// as NVIDIA's, runs only in a process built for the host's C library:
/// `-Dtarget=native-linux-gnu` links glibc through the standard dynamic linker, so the system
/// loader and its driver manifests resolve as they do for a shipped binary. The default build links
/// the pinned Nix glibc and reaches only drivers built against it, such as the pinned Mesa's
/// lavapipe or RADV named through `VK_DRIVER_FILES`, with the pinned loader on `LD_LIBRARY_PATH`.
/// Either mismatch ends in the skip below.
fn runVulkan(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var state = harness.VulkanState.initDevice(allocator, 0) catch |err| switch (err) {
        error.RuntimeUnavailable => {
            try writeJsonLine(
                writer,
                records.Skip{ .reason = "vulkan runtime unavailable", .backend = "vulkan" },
            );
            return;
        },
        else => return err,
    };
    defer state.deinit();

    try runAllCases(
        allocator,
        writer,
        "vulkan",
        state.handle(),
        .{ .mode = .execute, .assembler = null },
    );
}

fn runAllCases(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    backend_name: []const u8,
    handle: harness.BackendHandle,
    gate: harness.Gate,
) !void {
    const capabilities = try handle.queryCapabilities();
    var failures: usize = 0;
    var unsupported: usize = 0;
    var invalid: usize = 0;
    var assembled: usize = 0;
    var total_compile_ns: u64 = 0;
    var total_launch_read_ns: u64 = 0;

    inline for (cases.all) |Spec| {
        var case = caseResult(Spec, allocator, handle, gate, capabilities);
        case.backend = backend_name;
        try writeJsonLine(writer, case);
        total_compile_ns += case.compile_ns;
        total_launch_read_ns += case.launch_read_ns;
        if (std.mem.eql(u8, case.status, "unsupported")) {
            unsupported += 1;
        } else if (std.mem.eql(u8, case.status, "invalid")) {
            invalid += 1;
        } else if (std.mem.eql(u8, case.status, "assembled")) {
            assembled += 1;
        } else if (!std.mem.eql(u8, case.status, "pass")) {
            failures += 1;
        }
    }

    try writeJsonLine(writer, records.Summary{
        .backend = backend_name,
        .status = if (failures == 0) "pass" else "fail",
        .mode = @tagName(gate.mode),
        .cases = cases.all.len,
        .failures = failures,
        .unsupported = unsupported,
        .invalid = invalid,
        .assembled = assembled,
        .total_compile_ns = total_compile_ns,
        .total_launch_read_ns = total_launch_read_ns,
    });

    if (failures != 0) {
        try writer.flush();
        sys.process.exit(1);
    }
}

fn requestedBackend() !BackendChoice {
    return parseBackend(sys.env.get("ACCY_CONFORMANCE_BACKEND"));
}

fn parseBackend(raw: ?[]const u8) !BackendChoice {
    const value = raw orelse return .cuda;
    if (std.mem.eql(u8, value, "cuda")) return .cuda;
    if (std.mem.eql(u8, value, "metal")) return .metal;
    if (std.mem.eql(u8, value, "vulkan")) return .vulkan;
    return error.InvalidConformanceBackend;
}

test "conformance backend selection defaults to cuda" {
    try std.testing.expectEqual(BackendChoice.cuda, try parseBackend(null));
    try std.testing.expectEqual(BackendChoice.cuda, try parseBackend("cuda"));
    try std.testing.expectEqual(BackendChoice.metal, try parseBackend("metal"));
    try std.testing.expectEqual(BackendChoice.vulkan, try parseBackend("vulkan"));
    try std.testing.expectError(error.InvalidConformanceBackend, parseBackend("webgpu"));
}

fn caseResult(
    comptime Spec: type,
    allocator: std.mem.Allocator,
    handle: harness.BackendHandle,
    gate: harness.Gate,
    capabilities: gpu.BackendCapabilities,
) records.Case {
    if (comptime Spec.expectation != .invalid) {
        const required_dtypes = comptime harness.requiredDTypes(Spec);
        if (!capabilities.dtypes.containsAll(required_dtypes)) {
            return unsupportedCase(Spec, "BackendDTypeUnsupported");
        }
        const required_features = comptime harness.requiredFeatures(Spec);
        if (!capabilities.supportsFeatures(required_features)) {
            return unsupportedCase(Spec, "BackendFeatureUnsupported");
        }
        const required_subgroup = comptime harness.requiredSubgroup(Spec);
        if (!capabilities.supportsSubgroup(required_subgroup)) {
            return unsupportedCase(Spec, "BackendSubgroupUnsupported");
        }
    }

    const run_fn = comptime if (@hasDecl(
        Spec,
        "buildArtifact",
    )) harness.runFamilyCase else harness.runCase;
    const case = run_fn(Spec, allocator, handle, gate) catch |err| {
        const status: []const u8 = switch (Spec.expectation) {
            .verified => "fail",
            .unsupported => "unsupported",
            .invalid => "invalid",
        };
        return .{
            .name = Spec.name,
            .status = status,
            .detail = @errorName(err),
            .kernels = 0,
            .compile_ns = 0,
            .launch_read_ns = 0,
            .checksum = 0,
            .max_abs_error = std.math.floatMax(f32),
            .tolerance = Spec.tolerance,
        };
    };
    if (Spec.expectation == .unsupported) {
        var promoted = case;
        promoted.status = "fail";
        promoted.detail = "expected unsupported case compiled; promote it to verified";
        return promoted;
    }
    if (Spec.expectation == .invalid) {
        var promoted = case;
        promoted.status = "fail";
        promoted.detail = "expected semantically invalid case built a module; promote it";
        return promoted;
    }
    return case;
}

fn unsupportedCase(comptime Spec: type, detail: []const u8) records.Case {
    return .{
        .name = Spec.name,
        .status = "unsupported",
        .detail = detail,
        .kernels = 0,
        .compile_ns = 0,
        .launch_read_ns = 0,
        .checksum = 0,
        .max_abs_error = std.math.floatMax(f32),
        .tolerance = Spec.tolerance,
    };
}

fn forcedAssembleMode() bool {
    const mode = sys.env.get("ACCY_CONFORMANCE_MODE") orelse return false;
    return std.mem.eql(u8, mode, "assemble");
}

fn writeJsonLine(writer: *std.Io.Writer, value: anytype) !void {
    try pretty.json.writeMinified(writer, value);
    try writer.writeByte('\n');
}
