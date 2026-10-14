const std = @import("std");
const token = @import("token.zig");

pub const requires_max = 64;
pub const Result = struct {
    paths: [requires_max][]const u8 = undefined,
    count: usize = 0,
    requires: usize = 0,

    fn add(self: *Result, path: ?[]const u8) !void {
        if (self.requires == requires_max) return error.LakeRequiresCapacityExceeded;
        self.requires += 1;
        if (path) |value| {
            self.paths[self.count] = value;
            self.count += 1;
        }
    }
};

pub fn lean(bytes: []const u8) !Result {
    var lexer = token.Lexer{ .bytes = bytes, .lean = true };
    var result: Result = .{};
    while (true) {
        const next = try lexer.next();
        if (next.kind == .end) return result;
        if (!next.is("require")) continue;
        const name = try lexer.significant();
        if (name.kind != .word or !(try lexer.significant()).is("from"))
            return error.UnsupportedLakeRequire;
        const from = try lexer.significant();
        if (from.is("git")) {
            _ = try (try lexer.significant()).literal();
            const suffix = try lexer.next();
            if (suffix.is("@")) {
                _ = try (try lexer.significant()).literal();
                try endLine(&lexer);
            } else if (suffix.kind != .newline and suffix.kind != .end) {
                return error.UnsupportedLakeRequire;
            }
            try result.add(null);
        } else {
            const path = try from.literal();
            try endLine(&lexer);
            try result.add(path);
        }
    }
}

fn endLine(lexer: *token.Lexer) !void {
    const end = try lexer.next();
    if (end.kind != .newline and end.kind != .end) return error.UnsupportedLakeRequire;
}

const Require = struct {
    active: bool = false,
    fields: u8 = 0,
    path: ?[]const u8 = null,
    git: bool = false,

    fn finish(self: *Require, result: *Result) !void {
        if (!self.active) return;
        if (self.fields & 1 == 0 or (self.path != null) == self.git or
            (self.path != null and self.fields & ((1 << 3) | (1 << 5)) != 0))
            return error.UnsupportedLakeRequire;
        try result.add(self.path);
        self.* = .{};
    }

    fn field(self: *Require, key: token.Token, value: token.Token) !void {
        const keys = [_][]const u8{ "name", "path", "git", "rev", "scope", "subDir" };
        const index = for (keys, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, key.text)) break i;
        } else return error.UnsupportedLakeRequire;
        const bit = @as(u8, 1) << @as(u3, @intCast(index));
        if (self.fields & bit != 0) return error.InvalidLakeSyntax;
        self.fields |= bit;
        const literal = try value.literal();
        if (index == 1) self.path = literal;
        if (index == 2) self.git = true;
        // subDir changes a git checkout, not the root of a local path package.
        if (index == 5 and self.path != null) return error.UnsupportedLakeRequire;
    }
};

pub fn toml(bytes: []const u8) !Result {
    var lexer = token.Lexer{ .bytes = bytes, .lean = false };
    var result: Result = .{};
    var require: Require = .{};
    var start = true;
    while (true) {
        const next = try lexer.next();
        if (next.kind == .end) {
            try require.finish(&result);
            return result;
        }
        if (next.kind == .newline) {
            start = true;
            continue;
        }
        if (start and next.is("[")) {
            try require.finish(&result);
            const second = try lexer.next();
            const array = second.is("[");
            const name = if (array) try lexer.next() else second;
            if (std.mem.eql(u8, name.text, "require")) {
                if (!array or !(try lexer.next()).is("]") or !(try lexer.next()).is("]"))
                    return error.UnsupportedLakeRequire;
                try endLine(&lexer);
                require.active = true;
                start = true;
                continue;
            }
            if (std.mem.startsWith(u8, name.text, "require.")) return error.UnsupportedLakeRequire;
        } else if (start and !require.active and
            (std.mem.eql(u8, next.text, "require") or
                std.mem.startsWith(u8, next.text, "require.")))
        {
            return error.UnsupportedLakeRequire;
        } else if (start and require.active) {
            if ((next.kind != .word and next.kind != .string) or !(try lexer.next()).is("="))
                return error.UnsupportedLakeRequire;
            try require.field(next, try lexer.significant());
            try endLine(&lexer);
            start = true;
            continue;
        }
        start = false;
    }
}

const Package = struct {
    type: []const u8,
    dir: ?[]const u8 = null,
    inherited: ?bool = null,
    name: ?[]const u8 = null,
    manifestFile: ?[]const u8 = null,
    configFile: ?[]const u8 = null,
    url: ?[]const u8 = null,
    rev: ?[]const u8 = null,
};
const Manifest = struct { version: []const u8, packages: []const Package };

/// Lake's resolved path closure includes inherited packages. Unknown package
/// kinds refuse; a valid git record contributes no repository path.
pub fn manifest(arena: std.mem.Allocator, bytes: []const u8) !Result {
    const parsed = std.json.parseFromSlice(Manifest, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidLakeManifest,
    };
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.version, "1.2.0")) return error.UnsupportedLakeManifest;
    var result: Result = .{};
    for (parsed.value.packages) |package| {
        if (std.mem.eql(u8, package.type, "path")) {
            const path = package.dir orelse return error.InvalidLakeManifest;
            if (path.len == 0) return error.InvalidLakeManifest;
            try result.add(try arena.dupe(u8, path));
        } else if (std.mem.eql(u8, package.type, "git")) {
            try result.add(null);
        } else return error.UnsupportedLakeManifest;
    }
    return result;
}

fn parseLeanForTest(bytes: []const u8) !void {
    _ = try lean(bytes);
}
