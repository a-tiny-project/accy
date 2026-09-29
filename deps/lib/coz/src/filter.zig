const std = @import("std");

pub fn pathHasPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (prefix.len > path.len) return false;
    if (!std.mem.eql(u8, path[0..prefix.len], prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

pub fn isSystemPath(normalized: []const u8) bool {
    const prefixes = [_][]const u8{
        "/usr/include",
        "/usr/lib",
        "/usr/local/include",
        "/usr/local/lib",
        "/lib",
        "/lib64",
    };

    for (prefixes) |prefix| {
        if (pathHasPrefix(normalized, prefix)) return true;
    }
    return false;
}

pub fn isCozHeader(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "/coz.h");
}

pub fn wildcardMatch(subject: []const u8, pattern: []const u8) bool {
    return wildcardMatchRange(subject, pattern);
}

pub fn inScopeNormalized(normalized: []const u8, scope: []const []const u8) bool {
    for (scope) |pattern| {
        if (wildcardMatch(normalized, pattern)) return true;
    }
    return false;
}

pub fn fileMatchesScopeNormalized(
    normalized: []const u8,
    scope: []const []const u8,
    allow_system_sources: bool,
) bool {
    if (normalized.len == 0) return false;
    if (isCozHeader(normalized)) return false;
    if (!allow_system_sources and isSystemPath(normalized)) return false;
    if (scope.len == 0) return true;
    return inScopeNormalized(normalized, scope);
}

fn wildcardMatchRange(subject: []const u8, pattern: []const u8) bool {
    if ((pattern.len == 0) != (subject.len == 0)) return false;
    if (pattern.len == 0 and subject.len == 0) return true;

    if (pattern[0] == '%') {
        var match_end = subject.len;
        while (true) {
            if (wildcardMatchRange(subject[match_end..], pattern[1..])) return true;
            if (match_end == 0) break;
            match_end -= 1;
        }
        return false;
    }

    var index: usize = 0;
    while (index < subject.len and index < pattern.len and pattern[index] != '%') : (index += 1) {
        if (pattern[index] != subject[index]) return false;
    }

    return wildcardMatchRange(subject[index..], pattern[index..]);
}

test "system include and library paths are detected" {
    try std.testing.expect(isSystemPath("/usr/include/stdio.h"));
    try std.testing.expect(isSystemPath("/usr/include/c++/11/string"));
    try std.testing.expect(isSystemPath("/usr/lib/gcc/x86_64-linux-gnu/11/include/stddef.h"));
    try std.testing.expect(isSystemPath("/usr/local/include/boost/asio.hpp"));
    try std.testing.expect(isSystemPath("/usr/local/lib/libfoo.so"));
    try std.testing.expect(isSystemPath("/lib/x86_64-linux-gnu/libc.so.6"));
    try std.testing.expect(isSystemPath("/lib64/ld-linux-x86-64.so.2"));
}

test "user paths are not system paths" {
    try std.testing.expect(!isSystemPath("/home/user/project/src/main.cpp"));
    try std.testing.expect(!isSystemPath("/opt/app/lib/mylib.so"));
    try std.testing.expect(!isSystemPath("/tmp/build/output.o"));
}

test "coz header paths are detected" {
    try std.testing.expect(isCozHeader("/usr/include/coz.h"));
    try std.testing.expect(isCozHeader("/home/user/git/coz/include/coz.h"));
    try std.testing.expect(isCozHeader("/coz.h"));
}

test "non-coz header paths are not detected" {
    try std.testing.expect(!isCozHeader("/usr/include/coz_utils.h"));
    try std.testing.expect(!isCozHeader("/home/user/coz.cpp"));
    try std.testing.expect(!isCozHeader("/home/user/mycoz.h"));
}

test "path prefix matching requires a component boundary" {
    try std.testing.expect(pathHasPrefix("/usr/include/stdio.h", "/usr/include"));
    try std.testing.expect(pathHasPrefix("/usr/include", "/usr/include"));
    try std.testing.expect(!pathHasPrefix("/usr/includes/foo.h", "/usr/include"));
    try std.testing.expect(!pathHasPrefix("/usr", "/usr/include"));
    try std.testing.expect(!pathHasPrefix("", "/usr"));
    try std.testing.expect(!pathHasPrefix("/usr/include", ""));
}

test "wildcard matching follows upstream percent semantics" {
    try std.testing.expect(wildcardMatch("/usr/include/stdio.h", "/usr/%/stdio.h"));
    try std.testing.expect(wildcardMatch("/home/user/project/src/main.rs", "%"));
    try std.testing.expect(wildcardMatch("/opt/app/file.zig", "/opt/%/file.zig"));
    try std.testing.expect(!wildcardMatch("", "%"));
    try std.testing.expect(!wildcardMatch("/opt", "/opt/%"));
    try std.testing.expect(!wildcardMatch("/usr/includes/foo.h", "/usr/include/%"));
}

test "scope wildcard admits non-system user source paths" {
    const scope = [_][]const u8{"%"};

    try std.testing.expect(fileMatchesScopeNormalized("/home/user/project/src/main.rs", &scope, true));
    try std.testing.expect(fileMatchesScopeNormalized("/home/user/project/src/main.cpp", &scope, true));
}

test "coz headers are filtered in every scope" {
    const default_scope = [_][]const u8{"%"};
    const explicit_scope = [_][]const u8{"/usr/include/%"};

    try std.testing.expect(!fileMatchesScopeNormalized("/usr/include/coz.h", &default_scope, true));
    try std.testing.expect(!fileMatchesScopeNormalized("/usr/include/coz.h", &explicit_scope, true));
}

test "empty scope allows nonempty non-header paths" {
    const empty_scope = [_][]const u8{};

    try std.testing.expect(fileMatchesScopeNormalized("/opt/app/file.zig", &empty_scope, true));
    try std.testing.expect(fileMatchesScopeNormalized("/home/user/project/src/main.rs", &empty_scope, true));
}

test "system source filtering honors the allow flag" {
    const scope = [_][]const u8{"%"};

    try std.testing.expect(!fileMatchesScopeNormalized("/usr/include/stdio.h", &scope, false));
    try std.testing.expect(fileMatchesScopeNormalized("/usr/include/stdio.h", &scope, true));
}
