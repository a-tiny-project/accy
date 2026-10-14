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
