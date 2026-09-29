const std = @import("std");
const gpu = @import("gpu");
const pretty = @import("pretty");
const sys = @import("sys");

const Allocator = std.mem.Allocator;

const target_candidates = [_][]const u8{ "sm_75", "sm_70", "sm_80", "sm_86", "sm_89", "sm_90", "sm_100", "sm_52" };

pub fn probeTarget(allocator: Allocator) Allocator.Error!?[]const u8 {
    const argv = [_][]const u8{ "ptxas", "--help" };
    const result = run(allocator, &argv) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!exitedZero(result.term)) return null;
    for (target_candidates) |candidate| {
        if (std.mem.indexOf(u8, result.stdout, candidate) == null and
            std.mem.indexOf(u8, result.stderr, candidate) == null) continue;
        if (targetMajor(candidate) < 5) continue;
        return candidate;
    }
    return null;
}

pub fn acceptArtifact(
    allocator: Allocator,
    dir: []const u8,
    target: []const u8,
    artifact: gpu.KernelArtifact,
) !void {
    const text = switch (artifact.payload) {
        .text => |ptx_text| ptx_text,
        .bytes => |bytes| bytes,
        else => return error.InvalidArtifact,
    };
    try acceptText(allocator, dir, target, artifact.entry_name, text);
}

pub fn acceptText(
    allocator: Allocator,
    dir: []const u8,
    target: []const u8,
    entry_name: []const u8,
    text: []const u8,
) !void {
    const ptx_file = try std.fmt.allocPrint(allocator, "{s}.ptx", .{entry_name});
    defer allocator.free(ptx_file);
    const cubin_file = try std.fmt.allocPrint(allocator, "{s}.cubin", .{entry_name});
    defer allocator.free(cubin_file);

    const ptx_path = try sys.path.join(allocator, &.{ dir, ptx_file });
    defer allocator.free(ptx_path);
    const cubin_path = try sys.path.join(allocator, &.{ dir, cubin_file });
    defer allocator.free(cubin_path);
    try sys.fs.writeFile(ptx_path, text);

    const arch = try std.fmt.allocPrint(allocator, "-arch={s}", .{target});
    defer allocator.free(arch);

    const argv = [_][]const u8{ "ptxas", arch, "-o", cubin_path, ptx_path };
    const result = try run(allocator, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!exitedZero(result.term)) {
        pretty.diagnostic.writeStderrText("ptxas rejected {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{
            entry_name,
            result.stdout,
            result.stderr,
        });
        return error.PtxasRejected;
    }
}

pub fn scratchDir(allocator: Allocator) ![]u8 {
    const base = sys.env.get("TMPDIR") orelse "/tmp";
    const pid = sys.process.currentProcessId() catch 0;
    const dir = try std.fmt.allocPrint(allocator, "{s}/accy-ptx-validation-{d}", .{ base, pid });
    errdefer allocator.free(dir);
    try sys.fs.createDirPath(dir);
    return dir;
}

pub fn removeScratchDir(allocator: Allocator, dir: []u8) void {
    sys.fs.deleteTree(dir) catch {};
    allocator.free(dir);
}

fn run(allocator: Allocator, argv: []const []const u8) !sys.process.RunResult {
    var io_state = std.Io.Threaded.init(allocator, .{ .environ = sys.env.current() });
    defer io_state.deinit();
    return sys.process.run(allocator, io_state.io(), .{
        .argv = argv,
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
}

fn targetMajor(target: []const u8) u8 {
    if (!std.mem.startsWith(u8, target, "sm_")) return 0;
    return std.fmt.parseInt(u8, target[3..5], 10) catch 0;
}

fn exitedZero(term: sys.process.Termination) bool {
    return sys.process.exitCode(term) == 0;
}

test "target candidates all parse a major version" {
    for (target_candidates) |candidate| {
        try std.testing.expect(targetMajor(candidate) > 0);
    }
}

test "accept rejects artifacts without payloads" {
    var artifact = try gpu.KernelArtifact.init(std.testing.allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = "empty",
        .argument_count = 0,
        .diagnostic_id = null,
    });
    defer artifact.deinit();
    try std.testing.expectError(
        error.InvalidArtifact,
        acceptArtifact(std.testing.allocator, "/tmp", "sm_75", artifact),
    );
}

test "scratch directory is created and removable" {
    const dir = try scratchDir(std.testing.allocator);
    try std.testing.expect(sys.fs.exists(dir));
    removeScratchDir(std.testing.allocator, dir);
}
