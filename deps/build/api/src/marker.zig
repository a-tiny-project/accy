const std = @import("std");

const fs_io = std.Options.debug_io;
pub const schema = "tiny.build.iteration-generation/v1";
const maximum_token_bytes: usize = 128;
const maximum_step_bytes: usize = 256;
const maximum_diff_bytes: usize = 16 * 1024 * 1024;
const maximum_untracked_files: usize = 4096;
const maximum_untracked_bytes: usize = 16 * 1024 * 1024;
const maximum_untracked_path_bytes: usize = 4096;
const maximum_inventory_bytes = maximum_untracked_files * (maximum_untracked_path_bytes + 1);
const Overflow = enum { untracked_files, untracked_bytes, untracked_paths };
const Fingerprint = union(enum) {
    digest: Digest,
    overflow: Overflow,
};
const maximum_git_stderr_bytes: usize = 4096;
const context_bytes_max: usize = 128;
const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;
const digest_hex_bytes: usize = std.crypto.hash.sha2.Sha256.digest_length * 2;
const maximum_tree_id_bytes: usize = 64;
const tree_domain = "\x00tracked-tree\x00";
const diff_domain = "\x00tracked-diff\x00";

/// One bounded immutable tracked-tree identity for the captured baseline.
const TreeId = struct {
    storage: [maximum_tree_id_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const TreeId) []const u8 {
        std.debug.assert(self.len <= maximum_tree_id_bytes);
        return self.storage[0..self.len];
    }
};

const Capture = struct {
    tree: TreeId,
    fingerprint: Fingerprint,
};

const Context = struct {
    epoch: u64,
    worktree_sha256: Digest,
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stderr().writer(fs_io, &buffer);
        writer.interface.print(
            "iteration marker: {s}\n",
            .{@errorName(err)},
        ) catch {};
        writer.interface.flush() catch {};
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "fingerprint")) {
        try writeFingerprint(init, args[2]);
        return 0;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "trigger")) {
        try snapshotRequest(args[2], args[3]);
        return 0;
    }
    if (args.len != 5 and args.len != 6) return error.InvalidArguments;
    const mode = args[1][0..args[1].len];
    const directory = args[2][0..args[2].len];
    const token = args[3][0..args[3].len];
    const step = args[4][0..args[4].len];
    try validate(directory, token, step);
    if (args.len == 6 and std.mem.eql(u8, mode, "begin")) {
        try begin(init, directory, token, args[5]);
        return 0;
    }
    if (args.len != 5) return error.InvalidArguments;
    if (std.mem.eql(u8, mode, "finish")) {
        try finish(init, directory, token, step);
        return 0;
    }
    if (std.mem.eql(u8, mode, "complete")) {
        try complete(init, directory, token, step);
        return 0;
    }
    return error.InvalidMode;
}

fn begin(
    init: std.process.Init,
    directory: []const u8,
    token: []const u8,
    request_path: []const u8,
) !void {
    if (!std.fs.path.isAbsolute(request_path)) {
        return error.InvalidRequestPath;
    }
    try std.Io.Dir.cwd().createDirPath(fs_io, directory);
    const root = try worktreeRoot(init);
    try writeProbeMetadata(init, directory, token, root);
    var context_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const context_path = try contextPath(
        &context_path_buffer,
        directory,
        token,
    );
    std.Io.Dir.deleteFileAbsolute(fs_io, context_path) catch {};
    const request = try readRequest(request_path) orelse return;
    const capture = try captureWorktree(init, root);
    const fingerprint = switch (capture.fingerprint) {
        .digest => |digest| digest,
        .overflow => return,
    };
    try requireStableTree(init, root, capture.tree);
    if (!std.mem.eql(u8, &request.worktree_sha256, &fingerprint)) return;
    try writeContext(directory, token, request);
}

fn finish(
    init: std.process.Init,
    directory: []const u8,
    token: []const u8,
    step: []const u8,
) !void {
    var context_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const context_path = try contextPath(
        &context_path_buffer,
        directory,
        token,
    );
    defer std.Io.Dir.deleteFileAbsolute(fs_io, context_path) catch {};
    const context = readContext(context_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try readMetadata(
        directory,
        token,
        "worktree-root",
        &root_buffer,
    );
    const capture = try captureWorktree(init, root);
    const fingerprint = switch (capture.fingerprint) {
        .digest => |digest| digest,
        .overflow => return,
    };
    try requireStableTree(init, root, capture.tree);
    if (!std.mem.eql(u8, &context.worktree_sha256, &fingerprint)) return;

    try emitReceipt(directory, token, step, context, fingerprint);
}

fn complete(
    init: std.process.Init,
    directory: []const u8,
    token: []const u8,
    step: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(fs_io, directory);
    const root = try worktreeRoot(init);
    const capture = try captureWorktree(init, root);
    const fingerprint = switch (capture.fingerprint) {
        .digest => |digest| digest,
        .overflow => return error.UntrackedFingerprintOverflow,
    };
    try requireStableTree(init, root, capture.tree);
    try writeProbeMetadata(init, directory, token, root);
    try emitReceipt(
        directory,
        token,
        step,
        .{ .epoch = 0, .worktree_sha256 = fingerprint },
        fingerprint,
    );
}

fn emitReceipt(
    directory: []const u8,
    token: []const u8,
    step: []const u8,
    context: Context,
    fingerprint: Digest,
) !void {
    const finished_unix_ns = std.Io.Timestamp.now(fs_io, .real).nanoseconds;
    const fingerprint_hex = std.fmt.bytesToHex(fingerprint, .lower);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}-epoch-{d}-state-{s}-build-{d}.json",
        .{
            directory,
            token,
            context.epoch,
            &fingerprint_hex,
            finished_unix_ns,
        },
    );
    try writeReceiptFile(
        path,
        token,
        step,
        context.epoch,
        fingerprint,
        finished_unix_ns,
    );
}

fn writeFingerprint(init: std.process.Init, root: []const u8) !void {
    if (!std.fs.path.isAbsolute(root)) return error.InvalidWorktreeRoot;
    const capture = try captureWorktree(init, root);
    try requireStableTree(init, root, capture.tree);
    var buffer: [digest_hex_bytes + 1]u8 = undefined;
    var writer = std.Io.File.stdout().writer(fs_io, &buffer);
    switch (capture.fingerprint) {
        .digest => |digest| {
            const fingerprint_hex = std.fmt.bytesToHex(digest, .lower);
            try writer.interface.print("{s}\n", .{&fingerprint_hex});
        },
        .overflow => |reason| try writer.interface.print("overflow:{s}\n", .{@tagName(reason)}),
    }
    try writer.interface.flush();
}

fn worktreeRoot(init: std.process.Init) ![]const u8 {
    const result = try std.process.run(init.arena.allocator(), init.io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .stdout_limit = .limited(std.fs.max_path_bytes),
        .stderr_limit = .limited(maximum_git_stderr_bytes),
    });
    try requireSuccess(result.term);
    const root = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!std.fs.path.isAbsolute(root) or root.len >= std.fs.max_path_bytes) {
        return error.InvalidWorktreeRoot;
    }
    return root;
}

fn resolveTree(init: std.process.Init, root: []const u8) !TreeId {
    const result = try std.process.run(init.arena.allocator(), init.io, .{
        .argv = &.{ "git", "rev-parse", "--verify", "HEAD^{tree}" },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(maximum_tree_id_bytes + 2),
        .stderr_limit = .limited(maximum_git_stderr_bytes),
    });
    try requireSuccess(result.term);
    const identity = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (identity.len == 0 or identity.len > maximum_tree_id_bytes) {
        return error.InvalidTreeIdentity;
    }
    for (identity) |byte| {
        if (!std.ascii.isHex(byte)) return error.InvalidTreeIdentity;
    }
    var tree: TreeId = .{};
    @memcpy(tree.storage[0..identity.len], identity);
    tree.len = identity.len;
    return tree;
}

/// The tree must not move while the diff and untracked census run.
fn requireStableTree(
    init: std.process.Init,
    root: []const u8,
    expected: TreeId,
) !void {
    const observed = try resolveTree(init, root);
    if (!std.mem.eql(u8, expected.slice(), observed.slice())) {
        return error.TrackedBaselineChanged;
    }
}

fn captureWorktree(
    init: std.process.Init,
    root: []const u8,
) !Capture {
    const tree = try resolveTree(init, root);
    const argv = [_][]const u8{
        "git",           "diff",     "--no-ext-diff",
        "--no-textconv", "--binary", "--no-color",
        tree.slice(),    "--",
    };
    const result = try std.process.run(init.arena.allocator(), init.io, .{
        .argv = &argv,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(maximum_diff_bytes),
        .stderr_limit = .limited(maximum_git_stderr_bytes),
    });
    try requireSuccess(result.term);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(tree_domain);
    hash.update(tree.slice());
    hash.update(diff_domain);
    hash.update(result.stdout);
    return .{
        .tree = tree,
        .fingerprint = try hashUntracked(init, root, &hash),
    };
}

fn hashUntracked(
    init: std.process.Init,
    root: []const u8,
    hash: *std.crypto.hash.sha2.Sha256,
) !Fingerprint {
    const inventory = std.process.run(init.arena.allocator(), init.io, .{
        .argv = &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(maximum_inventory_bytes),
        .stderr_limit = .limited(maximum_git_stderr_bytes),
    }) catch |err| switch (err) {
        error.StreamTooLong => return .{ .overflow = .untracked_paths },
        else => return err,
    };
    try requireSuccess(inventory.term);
    var paths = std.mem.splitScalar(u8, inventory.stdout, 0);
    var count: usize = 0;
    var total: usize = 0;
    while (count <= maximum_untracked_files) : (count += 1) {
        const path = paths.next() orelse break;
        if (path.len == 0) break;
        if (count == maximum_untracked_files) return .{ .overflow = .untracked_files };
        if (path.len >= maximum_untracked_path_bytes) return .{ .overflow = .untracked_paths };
        hash.update("\x00untracked\x00");
        hash.update(path);
        hash.update("\x00");
        if (try hashUntrackedFile(root, path, hash, &total)) |overflow| {
            return .{ .overflow = overflow };
        }
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return .{ .digest = digest };
}

fn hashUntrackedFile(
    root: []const u8,
    path: []const u8,
    hash: *std.crypto.hash.sha2.Sha256,
    total: *usize,
) !?Overflow {
    std.debug.assert(total.* <= maximum_untracked_bytes);
    var directory = try std.Io.Dir.openDirAbsolute(fs_io, root, .{});
    defer directory.close(fs_io);
    const stat = try directory.statFile(fs_io, path, .{ .follow_symlinks = false });
    var buffer: [64 * 1024]u8 = undefined;
    var content = std.crypto.hash.sha2.Sha256.init(.{});
    if (stat.kind == .sym_link) {
        const length = try directory.readLink(fs_io, path, buffer[0..maximum_untracked_path_bytes]);
        if (length > maximum_untracked_bytes - total.*) return .untracked_bytes;
        total.* += length;
        content.update("symlink\x00");
        content.update(buffer[0..length]);
    } else {
        if (stat.kind != .file) return error.InvalidUntrackedFile;
        if (stat.size > maximum_untracked_bytes - total.*) return .untracked_bytes;
        var file = try directory.openFile(fs_io, path, .{});
        defer file.close(fs_io);
        var offset: u64 = 0;
        for (0..maximum_untracked_bytes / buffer.len + 1) |_| {
            const limit = @min(buffer.len, maximum_untracked_bytes - total.* + 1);
            const length = try file.readPositional(fs_io, &.{buffer[0..limit]}, offset);
            if (length == 0) break;
            if (length > maximum_untracked_bytes - total.*) return .untracked_bytes;
            total.* += length;
            offset += length;
            content.update(buffer[0..length]);
        } else return .untracked_bytes;
    }
    var digest: Digest = undefined;
    content.final(&digest);
    hash.update(&digest);
    std.debug.assert(total.* <= maximum_untracked_bytes);
    return null;
}

fn requireSuccess(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

fn readRequest(path: []const u8) !?Context {
    var bytes: [context_bytes_max]u8 = undefined;
    const text = try readAbsolute(path, &bytes);
    if (std.mem.eql(u8, text, "idle\n")) return null;
    return try parseContext(text);
}

fn snapshotRequest(input_path: []const u8, output_path: []const u8) !void {
    if (!std.fs.path.isAbsolute(input_path) or
        !std.fs.path.isAbsolute(output_path))
    {
        return error.InvalidRequestPath;
    }
    var bytes: [context_bytes_max]u8 = undefined;
    const request = try readAbsolute(input_path, &bytes);
    if (!std.mem.eql(u8, request, "idle\n")) _ = try parseContext(request);
    try writeAtomic(output_path, request);
}

fn writeContext(
    directory: []const u8,
    token: []const u8,
    context: Context,
) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try contextPath(&path_buffer, directory, token);
    const fingerprint_hex = std.fmt.bytesToHex(
        context.worktree_sha256,
        .lower,
    );
    var text_buffer: [context_bytes_max]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &text_buffer,
        "{d}\n{s}\n",
        .{ context.epoch, &fingerprint_hex },
    );
    try writeAtomic(path, text);
    const retained = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}-epoch-{d}-state-{s}.context",
        .{ directory, token, context.epoch, &fingerprint_hex },
    );
    var existing: [context_bytes_max]u8 = undefined;
    const previous = readAbsolute(retained, &existing) catch |err| switch (err) {
        error.FileNotFound => return writeAtomic(retained, text),
        else => return err,
    };
    if (!std.mem.eql(u8, previous, text)) return error.InvalidContext;
}

fn readContext(path: []const u8) !Context {
    var bytes: [context_bytes_max]u8 = undefined;
    const text = try readAbsolute(path, &bytes);
    return parseContext(text);
}

fn parseContext(text: []const u8) !Context {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const epoch_text = lines.next() orelse return error.InvalidContext;
    const fingerprint_text = lines.next() orelse return error.InvalidContext;
    if (lines.next()) |trailing| {
        if (trailing.len != 0 or lines.next() != null) {
            return error.InvalidContext;
        }
    }
    const epoch = std.fmt.parseInt(u64, epoch_text, 10) catch
        return error.InvalidContext;
    if (fingerprint_text.len != digest_hex_bytes) return error.InvalidContext;
    for (fingerprint_text) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.InvalidContext;
        }
    }
    var fingerprint: Digest = undefined;
    _ = std.fmt.hexToBytes(&fingerprint, fingerprint_text) catch
        return error.InvalidContext;
    return .{
        .epoch = epoch,
        .worktree_sha256 = fingerprint,
    };
}

fn writeProbeMetadata(
    init: std.process.Init,
    directory: []const u8,
    token: []const u8,
    root: []const u8,
) !void {
    const executable = try std.process.executablePathAlloc(
        init.io,
        init.arena.allocator(),
    );
    if (!std.fs.path.isAbsolute(executable)) {
        return error.InvalidMarkerExecutable;
    }
    var executable_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_path = try metadataPath(
        &executable_path_buffer,
        directory,
        token,
        "fingerprint-exe",
    );
    try writeAtomic(executable_path, executable);
    var root_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = try metadataPath(
        &root_path_buffer,
        directory,
        token,
        "worktree-root",
    );
    try writeAtomic(root_path, root);
}

fn readMetadata(
    directory: []const u8,
    token: []const u8,
    name: []const u8,
    storage: []u8,
) ![]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try metadataPath(&path_buffer, directory, token, name);
    const text = try readAbsolute(path, storage);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.fs.path.isAbsolute(trimmed)) return error.InvalidMetadata;
    return trimmed;
}

fn writeReceiptFile(
    path: []const u8,
    token: []const u8,
    step: []const u8,
    epoch: u64,
    fingerprint: Digest,
    finished_unix_ns: i96,
) !void {
    var pending_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const pending = try std.fmt.bufPrint(&pending_buffer, "{s}.pending", .{path});
    defer std.Io.Dir.deleteFileAbsolute(fs_io, pending) catch {};
    var file = try std.Io.Dir.createFileAbsolute(
        fs_io,
        pending,
        .{ .truncate = true },
    );
    var open = true;
    defer if (open) file.close(fs_io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(fs_io, &buffer);
    try writeReceipt(
        &writer.interface,
        token,
        step,
        epoch,
        fingerprint,
        finished_unix_ns,
    );
    try writer.interface.flush();
    file.close(fs_io);
    open = false;
    try std.Io.Dir.renameAbsolute(pending, path, fs_io);
}

fn writeReceipt(
    writer: *std.Io.Writer,
    token: []const u8,
    step: []const u8,
    epoch: u64,
    fingerprint: Digest,
    finished_unix_ns: i96,
) !void {
    const fingerprint_hex = std.fmt.bytesToHex(fingerprint, .lower);
    try std.json.Stringify.value(.{
        .schema = schema,
        .token = token,
        .selected_step = step,
        .generation_epoch = epoch,
        .worktree_sha256 = &fingerprint_hex,
        .finished_unix_ns = finished_unix_ns,
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn writeAtomic(path: []const u8, text: []const u8) !void {
    var pending_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const pending = try std.fmt.bufPrint(&pending_buffer, "{s}.writing", .{path});
    defer std.Io.Dir.deleteFileAbsolute(fs_io, pending) catch {};
    var file = try std.Io.Dir.createFileAbsolute(
        fs_io,
        pending,
        .{ .truncate = true },
    );
    var open = true;
    defer if (open) file.close(fs_io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(fs_io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
    file.close(fs_io);
    open = false;
    try std.Io.Dir.renameAbsolute(pending, path, fs_io);
}

fn readAbsolute(path: []const u8, buffer: []u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(fs_io, path, .{});
    defer file.close(fs_io);
    var reader_buffer: [512]u8 = undefined;
    var reader = file.reader(fs_io, &reader_buffer);
    var used: usize = 0;
    while (used < buffer.len) {
        const count = reader.interface.readSliceShort(buffer[used..]) catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse error.ReadFailed,
        };
        if (count == 0) return buffer[0..used];
        used += count;
    }
    var extra: [1]u8 = undefined;
    if (try reader.interface.readSliceShort(&extra) != 0) {
        return error.FileTooLarge;
    }
    return buffer;
}

fn contextPath(
    buffer: []u8,
    directory: []const u8,
    token: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{s}/{s}.generation-context",
        .{ directory, token },
    );
}

fn metadataPath(
    buffer: []u8,
    directory: []const u8,
    token: []const u8,
    name: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{s}/{s}.{s}",
        .{ directory, token, name },
    );
}

fn validate(
    directory: []const u8,
    token: []const u8,
    step: []const u8,
) !void {
    if (!std.fs.path.isAbsolute(directory) or
        directory.len >= std.fs.max_path_bytes)
    {
        return error.InvalidReceiptDirectory;
    }
    if (token.len == 0 or token.len > maximum_token_bytes) {
        return error.InvalidReceiptToken;
    }
    for (token) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '.' and byte != '_' and byte != '-')
        {
            return error.InvalidReceiptToken;
        }
    }
    if (step.len == 0 or step.len > maximum_step_bytes or
        step[0] == '-' or std.mem.indexOfScalar(u8, step, 0) != null)
    {
        return error.InvalidSelectedStep;
    }
}
