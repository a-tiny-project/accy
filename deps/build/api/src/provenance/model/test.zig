const std = @import("std");

const model = @import("root.zig");
const resolve = model.resolve;
const revision_bytes = model.revision_bytes;
const source_base_bytes_max = model.source_base_bytes_max;
const source_prefix_bytes_max = model.source_prefix_bytes_max;
const version_bytes_max = model.version_bytes_max;
const writeStringModule = model.writeStringModule;

test "repository provenance preserves environment precedence" {
    const tiny = "1111111111111111111111111111111111111111";
    const github = "2222222222222222222222222222222222222222";
    const git = "3333333333333333333333333333333333333333";
    var tiny_storage: [source_base_bytes_max]u8 = undefined;
    const tiny_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = 1,
        .source_base_storage = &tiny_storage,
        .tiny_commit = tiny,
        .github_sha = github,
        .git_revision = git,
        .tiny_source_base = "https://example.invalid/source/" ++ tiny ++ "/",
        .tiny_version = "candidate",
    });
    try std.testing.expectEqualStrings(tiny, tiny_result.available.revision);
    try std.testing.expectEqualStrings(
        "https://example.invalid/source/",
        tiny_result.available.source_prefix,
    );
    try std.testing.expectEqualStrings("candidate", tiny_result.available.version);

    var github_storage: [source_base_bytes_max]u8 = undefined;
    const github_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = 1,
        .source_base_storage = &github_storage,
        .github_sha = github,
        .git_revision = git,
        .tiny_source_base = "https://example.invalid/source/" ++ github ++ "/",
    });
    try std.testing.expectEqualStrings(
        github,
        github_result.available.revision,
    );

    var git_storage: [source_base_bytes_max]u8 = undefined;
    const git_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = 1,
        .source_base_storage = &git_storage,
        .git_revision = git,
    });
    try std.testing.expectEqualStrings(git, git_result.available.revision);
    try std.testing.expectEqualStrings(
        "https://github.com/femtomc/tiny/blob/" ++ git ++ "/",
        git_result.available.source_base,
    );
    try std.testing.expectEqualStrings("26.7.0", git_result.available.version);

    var invalid_storage: [source_base_bytes_max]u8 = undefined;
    const invalid_revision_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = 1,
        .source_base_storage = &invalid_storage,
        .git_revision = "unknown",
    });
    try std.testing.expectEqual(
        model.Failure.identity_unavailable,
        invalid_revision_result.unavailable,
    );
    const mismatched_source_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = 1,
        .source_base_storage = &invalid_storage,
        .git_revision = git,
        .tiny_source_base = "https://example.invalid/source/" ++ tiny ++ "/",
    });
    try std.testing.expectEqual(
        model.Failure.identity_unavailable,
        mismatched_source_result.unavailable,
    );
}

test "repository provenance bounds and escapes generated values" {
    const revision = "1111111111111111111111111111111111111111";
    const prefix = "https://docs.invalid/";
    var storage: [source_base_bytes_max]u8 = undefined;
    const maximum_version: [version_bytes_max]u8 = @splat('v');
    const maximum_version_result = resolve(.{
        .fallback_version = &maximum_version,
        .minimum_source_prefix_bytes = prefix.len,
        .source_base_storage = &storage,
        .git_revision = revision,
        .tiny_source_base = prefix ++ revision ++ "/",
    });
    try std.testing.expectEqual(
        version_bytes_max,
        maximum_version_result.available.version.len,
    );
    const long_version: [version_bytes_max + 1]u8 = @splat('v');
    const long_version_result = resolve(.{
        .fallback_version = &long_version,
        .minimum_source_prefix_bytes = prefix.len,
        .source_base_storage = &storage,
        .git_revision = revision,
        .tiny_source_base = prefix ++ revision ++ "/",
    });
    try std.testing.expectEqual(
        model.Failure.version_capacity_exceeded,
        long_version_result.unavailable,
    );

    var maximum_source_base: [source_base_bytes_max]u8 = @splat('x');
    @memcpy(
        maximum_source_base[source_prefix_bytes_max..][0..revision_bytes],
        revision,
    );
    maximum_source_base[maximum_source_base.len - 1] = '/';
    const maximum_source_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = prefix.len,
        .source_base_storage = &storage,
        .git_revision = revision,
        .tiny_source_base = &maximum_source_base,
    });
    try std.testing.expectEqual(
        source_prefix_bytes_max,
        maximum_source_result.available.source_prefix.len,
    );
    var long_source_base: [source_base_bytes_max + 1]u8 = @splat('x');
    @memcpy(
        long_source_base[long_source_base.len - revision_bytes - 1 ..][0..revision_bytes],
        revision,
    );
    long_source_base[long_source_base.len - 1] = '/';
    const long_source_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = prefix.len,
        .source_base_storage = &storage,
        .git_revision = revision,
        .tiny_source_base = &long_source_base,
    });
    try std.testing.expectEqual(
        model.Failure.source_base_capacity_exceeded,
        long_source_result.unavailable,
    );

    const minimum_prefix_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = prefix.len,
        .source_base_storage = &storage,
        .git_revision = revision,
        .tiny_source_base = prefix ++ revision ++ "/",
    });
    try std.testing.expectEqualStrings(
        prefix,
        minimum_prefix_result.available.source_prefix,
    );
    const short_prefix_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = prefix.len,
        .source_base_storage = &storage,
        .git_revision = revision,
        .tiny_source_base = "https://docs.invalid" ++ revision ++ "/",
    });
    try std.testing.expectEqual(
        model.Failure.source_prefix_too_short,
        short_prefix_result.unavailable,
    );

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeStringModule(&output.writer, "\"\n\x00");
    try std.testing.expectEqualStrings(
        "pub const value: []const u8 = \"\\x22\\x0a\\x00\";\n",
        output.written(),
    );
    const maximum_value: [source_base_bytes_max]u8 = @splat('x');
    var maximum_output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer maximum_output.deinit();
    try writeStringModule(&maximum_output.writer, &maximum_value);
    try std.testing.expectEqual(
        "pub const value: []const u8 = \"".len +
            4 * source_base_bytes_max +
            "\";\n".len,
        maximum_output.written().len,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        maximum_output.written(),
        "pub const value: []const u8 = \"\\x78",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        maximum_output.written(),
        "\\x78\";\n",
    ));
    try std.testing.expectError(
        error.RepositoryValueCapacityExceeded,
        writeStringModule(&output.writer, &long_source_base),
    );
}

test "repository provenance cache key is revision stable" {
    const first = "1111111111111111111111111111111111111111";
    const second = "2222222222222222222222222222222222222222";
    const prefix = "https://github.com/femtomc/tiny/blob/";
    var first_storage: [source_base_bytes_max]u8 = undefined;
    const first_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = prefix.len,
        .source_base_storage = &first_storage,
        .tiny_commit = first,
        .git_revision = first,
        .tiny_source_base = prefix ++ first ++ "/",
    });
    var second_storage: [source_base_bytes_max]u8 = undefined;
    const second_result = resolve(.{
        .fallback_version = "26.7.0",
        .minimum_source_prefix_bytes = prefix.len,
        .source_base_storage = &second_storage,
        .tiny_commit = second,
        .git_revision = second,
        .tiny_source_base = prefix ++ second ++ "/",
    });
    try std.testing.expectEqualStrings(
        first_result.available.source_prefix,
        second_result.available.source_prefix,
    );
    try std.testing.expectEqualStrings(
        first_result.available.version,
        second_result.available.version,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        first_result.available.revision,
        second_result.available.revision,
    ));
}
