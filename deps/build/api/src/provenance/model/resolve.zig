const std = @import("std");

/// Exact lowercase hexadecimal Git revision width used by public source links.
pub const revision_bytes: usize = 40;
/// One fixed identity slot bounds generated code, child arguments, and links.
pub const source_base_bytes_max: usize = 4096;
/// Maximum revision-free prefix that can still form one complete source URL.
pub const source_prefix_bytes_max: usize =
    source_base_bytes_max - revision_bytes - 1;
/// Release labels share one bounded slot larger than supported CalVer forms.
pub const version_bytes_max: usize = 128;

pub const Inputs = struct {
    fallback_version: []const u8,
    minimum_source_prefix_bytes: usize,
    source_base_storage: *[source_base_bytes_max]u8,
    tiny_commit: ?[]const u8 = null,
    github_sha: ?[]const u8 = null,
    git_revision: []const u8,
    tiny_source_base: ?[]const u8 = null,
    tiny_version: ?[]const u8 = null,
};

pub const Values = struct {
    revision: []const u8,
    source_base: []const u8,
    source_prefix: []const u8,
    version: []const u8,
};

pub const Failure = enum {
    identity_unavailable,
    version_capacity_exceeded,
    source_base_capacity_exceeded,
    source_prefix_too_short,
};

pub const Resolution = union(enum) {
    available: Values,
    unavailable: Failure,
};

pub fn resolve(inputs: Inputs) Resolution {
    const version = inputs.tiny_version orelse inputs.fallback_version;
    if (version.len > version_bytes_max) {
        return .{ .unavailable = .version_capacity_exceeded };
    }
    const revision = inputs.tiny_commit orelse
        inputs.github_sha orelse
        inputs.git_revision;
    if (!validRevision(revision)) {
        return .{ .unavailable = .identity_unavailable };
    }
    const source_base = inputs.tiny_source_base orelse blk: {
        const prefix = "https://github.com/femtomc/tiny/blob/";
        const required = prefix.len + revision_bytes + 1;
        std.debug.assert(required <= source_base_bytes_max);
        @memcpy(inputs.source_base_storage[0..prefix.len], prefix);
        @memcpy(
            inputs.source_base_storage[prefix.len..][0..revision_bytes],
            revision,
        );
        inputs.source_base_storage[required - 1] = '/';
        break :blk inputs.source_base_storage[0..required];
    };
    if (source_base.len > source_base_bytes_max) {
        return .{ .unavailable = .source_base_capacity_exceeded };
    }
    if (!sourceBaseEndsWith(source_base, revision)) {
        return .{ .unavailable = .identity_unavailable };
    }
    const prefix_bytes = source_base.len - revision_bytes - 1;
    if (prefix_bytes < inputs.minimum_source_prefix_bytes) {
        return .{ .unavailable = .source_prefix_too_short };
    }
    std.debug.assert(prefix_bytes <= source_prefix_bytes_max);
    return .{ .available = .{
        .revision = revision,
        .source_base = source_base,
        .source_prefix = source_base[0..prefix_bytes],
        .version = version,
    } };
}

pub fn writeStringModule(writer: *std.Io.Writer, value: []const u8) !void {
    if (value.len > source_base_bytes_max) {
        return error.RepositoryValueCapacityExceeded;
    }
    try writer.writeAll("pub const value: []const u8 = \"");
    for (value) |byte| try writer.print("\\x{x:0>2}", .{byte});
    try writer.writeAll("\";\n");
}

pub fn validRevision(revision: []const u8) bool {
    if (revision.len != revision_bytes) return false;
    for (revision) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
}

pub fn sourceBaseEndsWith(source_base: []const u8, revision: []const u8) bool {
    if (source_base.len <= revision.len or source_base[source_base.len - 1] != '/') {
        return false;
    }
    const revision_start = source_base.len - revision.len - 1;
    return std.mem.eql(
        u8,
        source_base[revision_start .. source_base.len - 1],
        revision,
    );
}
