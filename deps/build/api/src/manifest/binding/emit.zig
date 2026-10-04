const std = @import("std");
const model = @import("root.zig").model;

pub fn main(init: std.process.Init) !void {
    const storage = try init.arena.allocator().alloc(u8, model.scratch_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    const allocator = fixed.allocator();
    var arguments = try init.minimal.args.iterateAllocator(allocator);
    defer arguments.deinit();
    std.debug.assert(arguments.skip());
    const output = arguments.next() orelse return error.MissingCompilerBindingOutput;
    const binary = arguments.next() orelse return error.MissingCompilerBindingBinary;
    const name = arguments.next() orelse return error.MissingCompilerBindingName;
    const kind = arguments.next() orelse return error.MissingCompilerBindingKind;
    const refusal = arguments.next() orelse return error.MissingCompilerBindingState;
    const manifest = arguments.next();
    const invocation = arguments.next();
    const compilation = arguments.next();
    if (arguments.next() != null) return error.UnexpectedCompilerBindingArgument;
    try exportRecord(allocator, init.io, .{
        .output = output,
        .binary = binary,
        .compiler = .{ .name = name, .kind = kind },
        .refusal = if (std.mem.eql(u8, refusal, "qualified")) null else refusal,
        .manifest = manifest,
        .invocation = invocation,
        .compilation = compilation,
    });
}

pub const Request = struct {
    output: []const u8,
    binary: []const u8,
    compiler: model.Compiler,
    refusal: ?[]const u8 = null,
    manifest: ?[]const u8 = null,
    invocation: ?[]const u8 = null,
    compilation: ?[]const u8 = null,
};

/// Maker gates cache success. This helper invalidates prior completion, replaces
/// payloads, and renames the completed record only after every write succeeds.
/// The next attempt removes an interrupted record and temporary record first;
/// qualified payloads are overwritten, and refused payloads are removed.
/// Ordinary failure attempts every known leaf cleanup and retains the failure
/// even if a leaf cannot be removed. Blocking directories are never traversed.
pub fn exportRecord(allocator: std.mem.Allocator, io: std.Io, request: Request) !void {
    return exportRecordInner(allocator, io, request) catch |err| {
        if (err == error.OutOfMemory) return error.CompilerBindingScratchExceeded;
        return err;
    };
}

fn exportRecordInner(allocator: std.mem.Allocator, io: std.Io, request: Request) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, request.output, .{});
    defer directory.close(io);
    errdefer {
        for (output_leaves) |leaf| directory.deleteFile(io, leaf) catch {};
    }
    try removeLeaf(directory, io, "record.json");
    try removeLeaf(directory, io, "record.json.tmp");
    try model.compiler(request.compiler);
    var record = model.Record{
        .status = if (request.refusal == null) .qualified else .refused,
        .refusal = request.refusal,
        .compile = request.compiler,
        .binary = try hashFile(io, request.binary),
        .manifest = null,
        .invocation = null,
        .compilation = null,
    };
    var payload: ?model.Payload = null;
    if (request.refusal) |refusal| {
        if (refusal.len == 0 or refusal.len > model.maximum_name_bytes) {
            return error.InvalidCompilerBindingRefusal;
        }
        if (request.manifest != null or request.invocation != null or request.compilation != null) {
            return error.AmbiguousCompilerBinding;
        }
    } else {
        const manifest_path = request.manifest orelse return error.MissingCompilerBindingManifest;
        const invocation_path = request.invocation orelse return error.MissingCompilerBindingInvocation;
        const compilation_path = request.compilation orelse return error.MissingCompilerBindingCompilation;
        payload = .{
            .manifest = try read(allocator, io, manifest_path, model.maximum_manifest_bytes),
            .invocation = try read(allocator, io, invocation_path, model.maximum_invocation_bytes),
            .compilation = try read(allocator, io, compilation_path, model.maximum_compilation_bytes),
        };
        try model.validate(allocator, request.compiler, payload.?);
        record.manifest = identity(manifest_path, payload.?.manifest);
        record.invocation = identity(invocation_path, payload.?.invocation);
        record.compilation = identity(compilation_path, payload.?.compilation);
    }
    var buffer: [model.maximum_record_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(record, .{}, &writer) catch return error.CompilerBindingRecordTooLarge;
    writer.writeByte('\n') catch return error.CompilerBindingRecordTooLarge;
    if (payload) |raw| {
        try directory.writeFile(io, .{ .sub_path = "manifest.bin", .data = raw.manifest });
        try directory.writeFile(io, .{ .sub_path = "invocation.json", .data = raw.invocation });
        try directory.writeFile(io, .{ .sub_path = "compilation.json", .data = raw.compilation });
    } else {
        for (output_leaves[2..]) |leaf| try removeLeaf(directory, io, leaf);
    }
    try directory.writeFile(io, .{ .sub_path = "record.json.tmp", .data = writer.buffered() });
    try directory.rename("record.json.tmp", directory, "record.json", io);
}

const output_leaves = [_][]const u8{
    "record.json", "record.json.tmp", "manifest.bin", "invocation.json", "compilation.json",
};

fn removeLeaf(directory: std.Io.Dir, io: std.Io, leaf: []const u8) !void {
    directory.deleteFile(io, leaf) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

fn identity(origin: []const u8, bytes: []const u8) model.Identity {
    return .{ .path = origin, .bytes = bytes.len, .sha256 = model.digest(bytes) };
}

fn read(allocator: std.mem.Allocator, io: std.Io, source: []const u8, limit: usize) ![]const u8 {
    try model.path(source);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(limit + 1)) catch |err| {
        if (err == error.StreamTooLong) return error.CompilerBindingLeafTooLarge;
        return err;
    };
    if (bytes.len > limit) return error.CompilerBindingLeafTooLarge;
    return bytes;
}

pub fn hashFile(io: std.Io, path: []const u8) !model.Identity {
    try model.path(path);
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.UnsupportedCompilerBindingBinary;
    if (before.size > model.maximum_binary_bytes) return error.CompilerBindingBinaryTooLarge;
    var buffer: [model.stream_bytes]u8 = undefined;
    var reader = file.reader(io, &.{});
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: u64 = 0;
    while (bytes <= model.maximum_binary_bytes) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        bytes += count;
        if (bytes > model.maximum_binary_bytes) return error.CompilerBindingBinaryTooLarge;
        hash.update(buffer[0..count]);
    }
    const after = try file.stat(io);
    if (bytes != before.size or bytes != after.size or before.inode != after.inode or
        !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime))
    {
        return error.CompilerBindingBinaryChanged;
    }
    return .{ .path = path, .bytes = bytes, .sha256 = std.fmt.bytesToHex(hash.finalResult(), .lower) };
}
