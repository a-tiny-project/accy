const std = @import("std");
const sys = @import("sys");
const archive = @import("archive.zig");

const Allocator = std.mem.Allocator;
const max_linker_script_bytes = 64 * 1024;

pub fn resolvePath(allocator: Allocator, search_paths: []const []const u8, library: []const u8, static_library_search: bool) ![]const u8 {
    if (search_paths.len == 0) return error.LibraryNotFound;
    for (search_paths) |dir| {
        if (std.mem.startsWith(u8, library, ":")) {
            const path = try std.fs.path.join(allocator, &.{ dir, library[1..] });
            if (fileExists(path)) return path;
            continue;
        }
        if (!static_library_search) {
            const shared_path = try std.fmt.allocPrint(allocator, "{s}/lib{s}.so", .{ dir, library });
            if (fileExists(shared_path)) return shared_path;
        }
        const archive_path = try std.fmt.allocPrint(allocator, "{s}/lib{s}.a", .{ dir, library });
        if (fileExists(archive_path)) return archive_path;
    }
    return error.LibraryNotFound;
}

pub fn resolveInputPaths(allocator: Allocator, search_paths: []const []const u8, library: []const u8, static_library_search: bool) anyerror![]const []const u8 {
    const path = try resolvePath(allocator, search_paths, library, static_library_search);
    if (pathLooksLikeBinaryInput(path)) return try allocator.dupe([]const u8, &.{path});
    if (try linkerScriptGroupPaths(allocator, path, search_paths, static_library_search)) |group_paths| {
        if (group_paths.len == 0) return error.InvalidArguments;
        return group_paths;
    }
    return error.InvalidArguments;
}

pub fn appendResolvedInputPaths(
    allocator: Allocator,
    input_paths: *std.ArrayListUnmanaged([]const u8),
    search_paths: []const []const u8,
    library: []const u8,
    static_library_search: bool,
) !void {
    const paths = try resolveInputPaths(allocator, search_paths, library, static_library_search);
    try input_paths.appendSlice(allocator, paths);
}

pub fn pathLooksLikeBinaryInput(path: []const u8) bool {
    var header: [8]u8 = undefined;
    const len = readFileHeader(path, &header) orelse return false;
    if (archive.isArchive(header[0..len])) return true;
    if (len >= std.elf.MAGIC.len and std.mem.eql(u8, header[0..std.elf.MAGIC.len], std.elf.MAGIC)) return true;
    return false;
}

pub fn linkerScriptGroupPaths(allocator: Allocator, path: []const u8, search_paths: []const []const u8, static_library_search: bool) anyerror!?[]const []const u8 {
    const bytes = try readSmallPathAlloc(allocator, path);
    return try parseLinkerScriptGroupPaths(allocator, path, bytes, search_paths, static_library_search);
}

fn fileExists(path: []const u8) bool {
    var file = if (std.fs.path.isAbsolute(path))
        sys.fs.openAbsoluteFile(path, .{}) catch return false
    else
        sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{}) catch return false;
    file.close(sys.fs.debugIo());
    return true;
}

fn readFileHeader(path: []const u8, header: *[8]u8) ?usize {
    var file = if (std.fs.path.isAbsolute(path))
        sys.fs.openAbsoluteFile(path, .{}) catch return null
    else
        sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{}) catch return null;
    defer file.close(sys.fs.debugIo());
    return sys.fs.readHandle(file, header) catch null;
}

fn readSmallPathAlloc(allocator: Allocator, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return try sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), path, allocator, .limited(max_linker_script_bytes));
    const parent = std.fs.path.dirname(path) orelse "/";
    const name = std.fs.path.basename(path);
    var dir = try sys.fs.openAbsoluteDir(parent, .{});
    defer dir.close(sys.fs.debugIo());
    return try dir.readFileAlloc(sys.fs.debugIo(), name, allocator, .limited(max_linker_script_bytes));
}

fn parseLinkerScriptGroupPaths(
    allocator: Allocator,
    script_path: []const u8,
    bytes: []const u8,
    search_paths: []const []const u8,
    static_library_search: bool,
) anyerror!?[]const []const u8 {
    var index: usize = 0;
    while (nextLinkerScriptToken(bytes, &index)) |token| {
        if (!linkerScriptGroupCommand(token)) continue;
        const open = nextLinkerScriptToken(bytes, &index) orelse return error.InvalidArguments;
        if (!std.mem.eql(u8, open, "(")) return error.InvalidArguments;
        var depth: usize = 1;
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        while (nextLinkerScriptToken(bytes, &index)) |group_token| {
            if (std.mem.eql(u8, group_token, "(")) {
                depth += 1;
                continue;
            }
            if (std.mem.eql(u8, group_token, ")")) {
                depth -= 1;
                if (depth == 0) return try paths.toOwnedSlice(allocator);
                continue;
            }
            if (linkerScriptNestingCommand(group_token)) continue;
            try appendLinkerScriptGroupTokenPaths(allocator, &paths, script_path, group_token, search_paths, static_library_search);
        }
        return error.InvalidArguments;
    }
    return null;
}

fn nextLinkerScriptToken(bytes: []const u8, index: *usize) ?[]const u8 {
    while (index.* < bytes.len) {
        const byte = bytes[index.*];
        if (std.ascii.isWhitespace(byte)) {
            index.* += 1;
            continue;
        }
        if (byte == '/' and index.* + 1 < bytes.len and bytes[index.* + 1] == '*') {
            index.* += 2;
            while (index.* + 1 < bytes.len and !(bytes[index.*] == '*' and bytes[index.* + 1] == '/')) index.* += 1;
            if (index.* + 1 >= bytes.len) return null;
            index.* += 2;
            continue;
        }
        break;
    }
    if (index.* >= bytes.len) return null;
    const start = index.*;
    const byte = bytes[index.*];
    if (byte == '(' or byte == ')') {
        index.* += 1;
        return bytes[start..index.*];
    }
    if (byte == '\'' or byte == '"') {
        index.* += 1;
        const token_start = index.*;
        while (index.* < bytes.len and bytes[index.*] != byte) index.* += 1;
        const token = bytes[token_start..index.*];
        if (index.* < bytes.len) index.* += 1;
        return token;
    }
    while (index.* < bytes.len and !std.ascii.isWhitespace(bytes[index.*]) and bytes[index.*] != '(' and bytes[index.*] != ')') index.* += 1;
    return bytes[start..index.*];
}

fn linkerScriptGroupCommand(token: []const u8) bool {
    return std.mem.eql(u8, token, "GROUP") or std.mem.eql(u8, token, "INPUT");
}

fn linkerScriptNestingCommand(token: []const u8) bool {
    return std.mem.eql(u8, token, "AS_NEEDED");
}

fn appendLinkerScriptGroupTokenPaths(
    allocator: Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
    script_path: []const u8,
    token: []const u8,
    search_paths: []const []const u8,
    static_library_search: bool,
) anyerror!void {
    if (token.len == 0) return error.InvalidArguments;
    if (std.mem.startsWith(u8, token, "-l") and token.len > 2) {
        const resolved = try resolveInputPaths(allocator, search_paths, token[2..], static_library_search);
        try paths.appendSlice(allocator, resolved);
        return;
    }
    if (std.mem.startsWith(u8, token, "-")) return error.InvalidArguments;
    try paths.append(allocator, try resolveLinkerScriptGroupPath(allocator, script_path, token, search_paths));
}

fn resolveLinkerScriptGroupPath(allocator: Allocator, script_path: []const u8, token: []const u8, search_paths: []const []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(token)) return try allocator.dupe(u8, token);
    const parent = std.fs.path.dirname(script_path);
    if (parent) |dir| {
        const relative_to_script = try std.fs.path.join(allocator, &.{ dir, token });
        if (fileExists(relative_to_script)) return relative_to_script;
    }
    for (search_paths) |dir| {
        const relative_to_search = try std.fs.path.join(allocator, &.{ dir, token });
        if (fileExists(relative_to_search)) return relative_to_search;
    }
    if (parent) |dir| return try std.fs.path.join(allocator, &.{ dir, token });
    return try allocator.dupe(u8, token);
}

test "library search resolves archives and linker script groups" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try tmp.dir.realPathFileAlloc(sys.fs.debugIo(), ".", arena);
    const library_dir = try std.fs.path.join(arena, &.{ root, "lib" });
    try sys.fs.createDirPath(library_dir);
    const direct_path = try std.fs.path.join(arena, &.{ library_dir, "libdirect.a" });
    try sys.fs.writeFile(direct_path, archive.magic);
    const member_path = try std.fs.path.join(arena, &.{ library_dir, "member.a" });
    try sys.fs.writeFile(member_path, archive.magic);
    const script_path = try std.fs.path.join(arena, &.{ library_dir, "libscript.a" });
    try sys.fs.writeFile(script_path, "/* GNU ld script */\nGROUP ( member.a )\n");
    const shared_path = try std.fs.path.join(arena, &.{ library_dir, "libdual.so" });
    try sys.fs.writeFile(shared_path, std.elf.MAGIC ++ "shared");
    const shared_archive_path = try std.fs.path.join(arena, &.{ library_dir, "libdual.a" });
    try sys.fs.writeFile(shared_archive_path, archive.magic);
    const alternate_dir = try std.fs.path.join(arena, &.{ root, "alternate" });
    try sys.fs.createDirPath(alternate_dir);
    const searched_member_path = try std.fs.path.join(arena, &.{ alternate_dir, "libsearched.so.1" });
    try sys.fs.writeFile(searched_member_path, std.elf.MAGIC ++ "searched");
    const dependency_path = try std.fs.path.join(arena, &.{ alternate_dir, "libdependency.a" });
    try sys.fs.writeFile(dependency_path, archive.magic);
    const dynamic_script_path = try std.fs.path.join(arena, &.{ library_dir, "libdynamic.so" });
    try sys.fs.writeFile(dynamic_script_path, "/* GNU ld script */\nGROUP ( libsearched.so.1 -ldependency )\n");

    const direct = try resolveInputPaths(arena, &.{library_dir}, "direct", true);
    try std.testing.expectEqual(@as(usize, 1), direct.len);
    try std.testing.expectEqualStrings(direct_path, direct[0]);

    const script = try resolveInputPaths(arena, &.{library_dir}, "script", true);
    try std.testing.expectEqual(@as(usize, 1), script.len);
    try std.testing.expectEqualStrings(member_path, script[0]);

    const dynamic = try resolveInputPaths(arena, &.{ library_dir, alternate_dir }, "dynamic", false);
    try std.testing.expectEqual(@as(usize, 2), dynamic.len);
    try std.testing.expectEqualStrings(searched_member_path, dynamic[0]);
    try std.testing.expectEqualStrings(dependency_path, dynamic[1]);

    const shared = try resolveInputPaths(arena, &.{library_dir}, "dual", false);
    try std.testing.expectEqual(@as(usize, 1), shared.len);
    try std.testing.expectEqualStrings(shared_path, shared[0]);

    const static = try resolveInputPaths(arena, &.{library_dir}, "dual", true);
    try std.testing.expectEqual(@as(usize, 1), static.len);
    try std.testing.expectEqualStrings(shared_archive_path, static[0]);
}
