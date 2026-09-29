const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const fs_io = std.Options.debug_io;
const magic = "JHMA";
const format_version: u16 = 1;
const header_bytes: usize = 48;

pub const Metadata = struct {
    schema: []const u8,
    revision: []const u8,
};

pub const Entry = struct {
    metadata: Metadata,
    payload: []const u8,
};

pub fn encodedSize(
    metadata: Metadata,
    payload_bytes: usize,
) error{ArtifactTooLarge}!usize {
    if (metadata.schema.len == 0) return error.ArtifactTooLarge;
    if (metadata.revision.len == 0) return error.ArtifactTooLarge;
    if (metadata.schema.len > std.math.maxInt(u16)) return error.ArtifactTooLarge;
    if (metadata.revision.len > std.math.maxInt(u16)) return error.ArtifactTooLarge;
    if (payload_bytes > std.math.maxInt(u32)) return error.ArtifactTooLarge;

    const with_schema = std.math.add(usize, header_bytes, metadata.schema.len) catch
        return error.ArtifactTooLarge;
    const with_revision = std.math.add(usize, with_schema, metadata.revision.len) catch
        return error.ArtifactTooLarge;
    return std.math.add(usize, with_revision, payload_bytes) catch
        return error.ArtifactTooLarge;
}

pub fn save(path: []const u8, metadata: Metadata, payload: []const u8) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(metadata.schema.len > 0);
    std.debug.assert(metadata.revision.len > 0);
    _ = try encodedSize(metadata, payload.len);

    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(fs_io, parent);
    }
    var header: [header_bytes]u8 = @splat(0);
    @memcpy(header[0..magic.len], magic);
    std.mem.writeInt(u16, header[4..6], format_version, .little);
    std.mem.writeInt(u16, header[8..10], @intCast(metadata.schema.len), .little);
    std.mem.writeInt(u16, header[10..12], @intCast(metadata.revision.len), .little);
    std.mem.writeInt(u32, header[12..16], @intCast(payload.len), .little);
    contentDigest(header[0..16], metadata, payload, header[16..48]);

    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(fs_io, path, .{ .replace = true });
    defer atomic_file.deinit(fs_io);
    var offset: u64 = 0;
    try atomic_file.file.writePositionalAll(fs_io, &header, offset);
    offset += header.len;
    try atomic_file.file.writePositionalAll(fs_io, metadata.schema, offset);
    offset += metadata.schema.len;
    try atomic_file.file.writePositionalAll(fs_io, metadata.revision, offset);
    offset += metadata.revision.len;
    try atomic_file.file.writePositionalAll(fs_io, payload, offset);
    try atomic_file.replace(fs_io);
}

pub fn load(path: []const u8, storage: []u8) !?Entry {
    std.debug.assert(path.len > 0);
    var file = std.Io.Dir.cwd().openFile(fs_io, path, .{ .allow_directory = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(fs_io);
    const stat = try file.stat(fs_io);
    if (stat.kind != .file) return error.InvalidArtifact;
    const file_len = std.math.cast(usize, stat.size) orelse return error.ArtifactTooLarge;
    if (file_len > storage.len) return error.ArtifactTooLarge;
    const data = storage[0..file_len];
    if (try file.readPositionalAll(fs_io, data, 0) != file_len) return error.InvalidArtifact;
    var trailing: [1]u8 = undefined;
    if (try file.readPositionalAll(fs_io, &trailing, file_len) != 0) {
        return error.InvalidArtifact;
    }
    return try decode(data);
}

fn decode(data: []const u8) !Entry {
    if (data.len < header_bytes) return error.InvalidArtifact;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidArtifact;
    if (std.mem.readInt(u16, data[4..6], .little) != format_version) {
        return error.UnsupportedArtifactVersion;
    }
    if (std.mem.readInt(u16, data[6..8], .little) != 0) return error.InvalidArtifact;
    const schema_len: usize = std.mem.readInt(u16, data[8..10], .little);
    const revision_len: usize = std.mem.readInt(u16, data[10..12], .little);
    const payload_len: usize = std.mem.readInt(u32, data[12..16], .little);
    const metadata_len = std.math.add(usize, schema_len, revision_len) catch
        return error.InvalidArtifact;
    const body_len = std.math.add(usize, metadata_len, payload_len) catch
        return error.InvalidArtifact;
    const expected_len = std.math.add(usize, header_bytes, body_len) catch
        return error.InvalidArtifact;
    if (data.len != expected_len) return error.InvalidArtifact;
    if (schema_len == 0 or revision_len == 0) return error.InvalidArtifact;

    const schema = data[header_bytes..][0..schema_len];
    const revision = data[header_bytes + schema_len ..][0..revision_len];
    const payload = data[header_bytes + metadata_len ..][0..payload_len];
    var digest: [Sha256.digest_length]u8 = undefined;
    contentDigest(
        data[0..16],
        .{ .schema = schema, .revision = revision },
        payload,
        &digest,
    );
    if (!std.crypto.timing_safe.eql([Sha256.digest_length]u8, digest, data[16..48].*)) {
        return error.InvalidArtifact;
    }
    return .{
        .metadata = .{ .schema = schema, .revision = revision },
        .payload = payload,
    };
}

fn contentDigest(
    header: []const u8,
    metadata: Metadata,
    payload: []const u8,
    output: *[Sha256.digest_length]u8,
) void {
    var hasher = Sha256.init(.{});
    hasher.update(header);
    hasher.update(metadata.schema);
    hasher.update(metadata.revision);
    hasher.update(payload);
    hasher.final(output);
}

test "artifact: materialized input retains schema revision and bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(fs_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/case.jhma", .{dir_path});
    const metadata = Metadata{
        .schema = "example.state-machine.v1",
        .revision = "generator-before-change",
    };
    try save(path, metadata, &.{ 3, 1, 4, 1, 5 });

    var storage: [256]u8 = undefined;
    try std.testing.expectEqual(
        header_bytes + metadata.schema.len + metadata.revision.len + 5,
        try encodedSize(metadata, 5),
    );
    const loaded = (try load(path, &storage)).?;
    try std.testing.expectEqualStrings(metadata.schema, loaded.metadata.schema);
    try std.testing.expectEqualStrings(metadata.revision, loaded.metadata.revision);
    try std.testing.expectEqualSlices(u8, &.{ 3, 1, 4, 1, 5 }, loaded.payload);
}

test "artifact: payload corruption is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(fs_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/case.jhma", .{dir_path});
    try save(path, .{ .schema = "example.v1", .revision = "one" }, "payload");
    var file = try std.Io.Dir.cwd().openFile(fs_io, path, .{ .mode = .read_write });
    defer file.close(fs_io);
    try file.writePositionalAll(fs_io, "X", header_bytes + "example.v1".len + "one".len);

    var storage: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidArtifact, load(path, &storage));
}
