const std = @import("std");

pub const schema = "tiny.compiled-inputs/v1";
pub const maximum_entries: u32 = 65536;
pub const maximum_compiles = 64;
pub const maximum_modules = 512;
pub const maximum_references = 4096;
pub const maximum_graph_bytes = 4 * 1024 * 1024;
/// Maximum link expansions along one logical input path, including ancestors.
pub const maximum_symlink_depth: u32 = 32;
/// The encoded length of a directory alias. No file reaches it, because a
/// file's length is at most `maximum_file_bytes`, so a reader that does not
/// know aliases refuses the record as an oversized file.
pub const alias_length: u64 = std.math.maxInt(u64);
pub const maximum_manifest_bytes: u32 = 16 * 1024 * 1024;
pub const maximum_path_bytes: u32 = 4096;
pub const maximum_file_bytes: u64 = 1024 * 1024 * 1024;
pub const maximum_total_bytes: u64 = 4 * 1024 * 1024 * 1024;

pub const Input = struct {
    path: []const u8,
    pinned: bool = false,
    directory: bool = false,
    generated: bool = false,
    assembly: ?std.Target.Cpu.Arch = null,
};

pub const Request = struct {
    inputs: []const Input,
    inherited: bool = false,
    compilation: bool = false,
};

/// Foreign bytes are identified by complete per-input SHA-256 records.
/// The resulting manifest is an owner product compared as exact bytes.
pub const Entry = struct {
    path: []const u8,
    pinned_source: []const u8,
    byte_length: u64,
    sha256: [32]u8,
    kind: Kind = .file,
};

/// An alias is a directory link that re-enters a directory open on the walk.
/// Its logical path names the directory whose canonical pinned path is
/// `pinned_source`, whose files carry their own entries. It holds no bytes.
pub const Kind = enum { file, alias };

/// Physical keys borrow canonical pinned paths from the capture or schema owner.
/// A null key preserves per-entry accounting for unpinned and generated inputs.
pub const ByteCounter = struct {
    const Identity = struct {
        byte_length: u64,
        sha256: [32]u8,
    };

    counted: std.StringHashMapUnmanaged(Identity) = .empty,
    logical_count: u32 = 0,
    bytes: u64 = 0,
    limit: u64 = maximum_total_bytes,

    pub fn deinit(self: *ByteCounter, allocator: std.mem.Allocator) void {
        self.counted.deinit(allocator);
        self.* = undefined;
    }

    pub fn add(
        self: *ByteCounter,
        allocator: std.mem.Allocator,
        physical_path: ?[]const u8,
        byte_length: u64,
        sha256: [32]u8,
    ) !void {
        std.debug.assert(self.logical_count <= maximum_entries);
        std.debug.assert(self.counted.count() <= self.logical_count);
        std.debug.assert(self.limit <= maximum_total_bytes);
        std.debug.assert(self.bytes <= self.limit);
        if (self.logical_count == maximum_entries) return error.CompilerInputCountExceeded;
        if (byte_length > maximum_file_bytes) return error.CompilerInputTooLarge;
        if (physical_path) |path| {
            std.debug.assert(path.len > 0);
            std.debug.assert(path.len <= maximum_path_bytes);
            std.debug.assert(path[0] == '/');
            if (self.counted.get(path)) |prior| {
                if (prior.byte_length != byte_length or !std.mem.eql(u8, &prior.sha256, &sha256)) {
                    return error.CompilerInputPhysicalIdentityMismatch;
                }
                self.logical_count += 1;
                return;
            }
        }
        const total = std.math.add(u64, self.bytes, byte_length) catch
            return error.CompilerInputBytesExceeded;
        if (total > self.limit) return error.CompilerInputBytesExceeded;
        if (physical_path) |path| {
            if (self.counted.capacity() == 0) {
                try self.counted.ensureTotalCapacity(allocator, maximum_entries);
            }
            std.debug.assert(self.counted.count() < maximum_entries);
            self.counted.putAssumeCapacityNoClobber(path, .{
                .byte_length = byte_length,
                .sha256 = sha256,
            });
        }
        self.bytes = total;
        self.logical_count += 1;
    }

    /// An alias is metadata: it takes an entry and no foreign bytes.
    pub fn alias(self: *ByteCounter) !void {
        std.debug.assert(self.logical_count <= maximum_entries);
        if (self.logical_count == maximum_entries) return error.CompilerInputCountExceeded;
        self.logical_count += 1;
    }
};

pub fn entry(path: []const u8, pin: []const u8, bytes: []const u8) !Entry {
    try validatePath(path);
    try validatePin(pin);
    if (bytes.len > maximum_file_bytes) return error.CompilerInputTooLarge;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{
        .path = path,
        .pinned_source = pin,
        .byte_length = bytes.len,
        .sha256 = digest,
    };
}

pub fn alias(path: []const u8, target: []const u8) !Entry {
    try validatePath(path);
    try validatePin(target);
    if (target.len == 0) return error.UnpinnedCompilerToolchain;
    return .{
        .path = path,
        .pinned_source = target,
        .byte_length = 0,
        .sha256 = @splat(0),
        .kind = .alias,
    };
}

fn validateAlias(item: Entry) !void {
    std.debug.assert(item.kind == .alias);
    if (item.pinned_source.len == 0 or item.byte_length != 0) return error.InvalidCompilerManifest;
    for (item.sha256) |byte| if (byte != 0) return error.InvalidCompilerManifest;
}

pub fn encode(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    if (entries.len > maximum_entries) return error.CompilerInputCountExceeded;
    const sorted = try allocator.dupe(Entry, entries);
    defer allocator.free(sorted);
    std.mem.sort(Entry, sorted, {}, less);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try output.writer.writeAll(schema);
    try output.writer.writeInt(u32, @intCast(sorted.len), .little);
    var counter: ByteCounter = .{};
    defer counter.deinit(allocator);
    for (sorted, 0..) |item, index| {
        try validatePath(item.path);
        try validatePin(item.pinned_source);
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].path, item.path)) {
            return error.DuplicateCompilerInput;
        }
        switch (item.kind) {
            .alias => {
                try validateAlias(item);
                try counter.alias();
            },
            .file => {
                const physical: ?[]const u8 = if (item.pinned_source.len == 0)
                    null
                else
                    item.pinned_source;
                try counter.add(allocator, physical, item.byte_length, item.sha256);
            },
        }
        try writeText(&output.writer, item.path);
        try writeText(&output.writer, item.pinned_source);
        try output.writer.writeInt(u64, switch (item.kind) {
            .alias => alias_length,
            .file => item.byte_length,
        }, .little);
        try output.writer.writeAll(&item.sha256);
        if (output.written().len > maximum_manifest_bytes) {
            return error.CompilerManifestTooLarge;
        }
    }
    return output.toOwnedSlice();
}

/// Returned fields borrow the validated byte string; only the entry array is allocated.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Entry {
    if (bytes.len > maximum_manifest_bytes) return error.CompilerManifestTooLarge;
    var reader = std.Io.Reader.fixed(bytes);
    if (!std.mem.eql(u8, try reader.take(schema.len), schema)) {
        return error.CompilerManifestSchemaMismatch;
    }
    const count = try reader.takeInt(u32, .little);
    if (count > maximum_entries) return error.CompilerInputCountExceeded;
    const entries = try allocator.alloc(Entry, count);
    errdefer allocator.free(entries);
    var counter: ByteCounter = .{};
    defer counter.deinit(allocator);
    for (entries, 0..) |*item, index| {
        item.* = .{
            .path = try readText(&reader),
            .pinned_source = try readText(&reader),
            .byte_length = try reader.takeInt(u64, .little),
            .sha256 = (try reader.takeArray(32)).*,
        };
        try validatePath(item.path);
        try validatePin(item.pinned_source);
        if (index > 0 and !less({}, entries[index - 1], item.*)) {
            return error.UnorderedCompilerInputs;
        }
        if (item.byte_length == alias_length) {
            item.byte_length = 0;
            item.kind = .alias;
            try validateAlias(item.*);
            try counter.alias();
            continue;
        }
        const physical: ?[]const u8 = if (item.pinned_source.len == 0)
            null
        else
            item.pinned_source;
        try counter.add(allocator, physical, item.byte_length, item.sha256);
    }
    if (reader.seek != bytes.len) return error.InvalidCompilerManifest;
    return entries;
}

fn less(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > maximum_path_bytes or path[0] == '/') {
        return error.InvalidCompilerInputPath;
    }
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return error.InvalidCompilerInputPath;
        }
        for (part) |byte| {
            if (byte < 32 or byte == 127 or byte == '\\') return error.InvalidCompilerInputPath;
        }
    }
}

pub fn validatePin(pin: []const u8) !void {
    if (pin.len == 0) return;
    const prefix = "/nix/store/";
    if (!std.mem.startsWith(u8, pin, prefix) or pin.len > maximum_path_bytes) {
        return error.UnpinnedCompilerToolchain;
    }
    const suffix = pin[prefix.len..];
    if (suffix.len < 34 or suffix[32] != '-') {
        return error.UnpinnedCompilerToolchain;
    }
    for (suffix[0..32]) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) return error.UnpinnedCompilerToolchain;
    }
    const root_end = std.mem.indexOfScalar(u8, suffix, '/') orelse suffix.len;
    if (root_end == 33) return error.UnpinnedCompilerToolchain;
    if (root_end < suffix.len) {
        validatePath(suffix[root_end + 1 ..]) catch return error.UnpinnedCompilerToolchain;
    }
    for (suffix[33..root_end]) |byte| {
        if (byte < 33 or byte == 127 or byte == '\\') return error.UnpinnedCompilerToolchain;
    }
}

fn writeText(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeInt(u32, @intCast(text.len), .little);
    try writer.writeAll(text);
}

fn readText(reader: *std.Io.Reader) ![]const u8 {
    const size = try reader.takeInt(u32, .little);
    if (size > maximum_path_bytes) return error.InvalidCompilerInputPath;
    return reader.take(size);
}
