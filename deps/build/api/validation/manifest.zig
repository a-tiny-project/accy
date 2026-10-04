const std = @import("std");
const Zoir = std.zig.Zoir;

pub const dependencies_max = 1024;
pub const bytes_max = 1024 * 1024;

/// The same typed data is imported by the root tool registry. Optional tool surfaces
/// still own source: availability does not erase affected-owner coverage obligations.
pub fn toolRoots(allocator: std.mem.Allocator, bytes: [:0]const u8) ![][]const u8 {
    if (bytes.len > bytes_max) return error.ValidationManifestCapacityExceeded;
    var ast = try std.zig.Ast.parse(allocator, bytes, .{ .mode = .zon });
    defer ast.deinit(allocator);
    var zoir = try std.zig.ZonGen.generate(allocator, ast, .{});
    defer zoir.deinit(allocator);
    if (zoir.hasCompileErrors()) return error.InvalidValidationManifest;
    const root = Zoir.Node.Index.root.get(&zoir);
    const schema = (try field(&zoir, root, "schema")) orelse
        return error.InvalidValidationToolCatalog;
    if (schema != .string_literal or
        !std.mem.eql(u8, schema.string_literal, "tiny.build.tool-catalog/v1"))
        return error.InvalidValidationToolCatalog;
    const tools = (try field(&zoir, root, "tools")) orelse
        return error.InvalidValidationToolCatalog;
    if (tools == .empty_literal) return allocator.alloc([]const u8, 0);
    if (tools != .struct_literal) return error.InvalidValidationToolCatalog;
    const entries = tools.struct_literal;
    if (entries.names.len > dependencies_max) return error.ValidationManifestCapacityExceeded;
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |path| allocator.free(path);
        result.deinit(allocator);
    }
    for (0..entries.vals.len) |index| {
        const tool = entries.vals.at(@intCast(index)).get(&zoir);
        const path = (try field(&zoir, tool, "source_root")) orelse
            return error.InvalidValidationToolCatalog;
        if (path != .string_literal or !validRoot(path.string_literal))
            return error.InvalidValidationToolCatalog;
        const owned = try allocator.dupe(u8, path.string_literal);
        errdefer allocator.free(owned);
        try result.append(allocator, owned);
    }
    return result.toOwnedSlice(allocator);
}

fn validRoot(path: []const u8) bool {
    if (path.len == 0 or !std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |byte| if (byte < 32 or byte == 127 or byte == '\\') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return false;
    }
    return true;
}

/// Return package-manager local dependencies; remote dependencies have no repository owner.
pub fn dependencies(allocator: std.mem.Allocator, bytes: [:0]const u8) ![][]const u8 {
    if (bytes.len > bytes_max) return error.ValidationManifestCapacityExceeded;
    var ast = try std.zig.Ast.parse(allocator, bytes, .{ .mode = .zon });
    defer ast.deinit(allocator);
    var zoir = try std.zig.ZonGen.generate(allocator, ast, .{});
    defer zoir.deinit(allocator);
    if (zoir.hasCompileErrors()) return error.InvalidValidationManifest;
    const root = Zoir.Node.Index.root.get(&zoir);
    const declarations = (try field(&zoir, root, "dependencies")) orelse
        return allocator.alloc([]const u8, 0);
    if (declarations == .empty_literal) return allocator.alloc([]const u8, 0);
    if (declarations != .struct_literal) return error.InvalidValidationManifest;
    const entries = declarations.struct_literal;
    if (entries.names.len > dependencies_max) return error.ValidationManifestCapacityExceeded;
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |path| allocator.free(path);
        result.deinit(allocator);
    }
    for (0..entries.vals.len) |index| {
        const dependency = entries.vals.at(@intCast(index)).get(&zoir);
        const path = (try field(&zoir, dependency, "path")) orelse continue;
        if (path != .string_literal or path.string_literal.len == 0) {
            return error.InvalidValidationManifest;
        }
        const owned = try allocator.dupe(u8, path.string_literal);
        errdefer allocator.free(owned);
        try result.append(allocator, owned);
    }
    return result.toOwnedSlice(allocator);
}

fn field(zoir: *const Zoir, object: Zoir.Node, name: []const u8) !?Zoir.Node {
    if (object == .empty_literal) return null;
    if (object != .struct_literal) return error.InvalidValidationManifest;
    for (object.struct_literal.names, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.get(zoir), name)) {
            return object.struct_literal.vals.at(@intCast(index)).get(zoir);
        }
    }
    return null;
}

test "validation manifest follows local paths and decodes quoted dependency names" {
    const allocator = std.testing.allocator;
    const result = try dependencies(allocator,
        \\.{ .name = .fixture, .dependencies = .{
        \\  .@"local-name" = .{ .path = "../core" },
        \\  .remote = .{ .url = "https://invalid.example/archive", .hash = "hash" },
        \\  .nested = .{ .path = "fixture/child", .lazy = true },
        \\} }
    );
    defer allocator.free(result);
    defer for (result) |path| allocator.free(path);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("../core", result[0]);
    try std.testing.expectEqualStrings("fixture/child", result[1]);
}

test "validation manifest fails malformed declarations and permits no dependencies" {
    const allocator = std.testing.allocator;
    const empty = try dependencies(allocator, ".{ .name = .fixture }");
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    for ([_][:0]const u8{
        ".{ .dependencies = 42 }",
        ".{ .dependencies = .{ .core = .{ .path = 42 } } }",
        ".{ .dependencies = .{ .core = .{ .path = \"\" } } }",
        ".{ .dependencies = .{ .core = .{ .path = \"a\", .path = \"b\" } } }",
    }) |bytes| {
        try std.testing.expectError(error.InvalidValidationManifest, dependencies(allocator, bytes));
    }
}

test "validation tool roots retain source-composed and optional tool ownership" {
    const allocator = std.testing.allocator;
    const paths = try toolRoots(allocator,
        \\.{ .schema = "tiny.build.tool-catalog/v1", .tools = .{
        \\  .optional = .{ .source_root = "tools/style", .available = .style },
        \\  .package = .{ .source_root = "research/chic", .dependency = "chic" },
        \\} }
    );
    defer allocator.free(paths);
    defer for (paths) |path| allocator.free(path);
    try std.testing.expectEqual(2, paths.len);
    try std.testing.expectEqualStrings("tools/style", paths[0]);
    try std.testing.expectEqualStrings("research/chic", paths[1]);
    for ([_][:0]const u8{
        ".{}",
        ".{ .schema = \"unknown\", .tools = .{} }",
        ".{ .schema = \"tiny.build.tool-catalog/v1\", .tools = 1 }",
        ".{ .schema = \"tiny.build.tool-catalog/v1\", .tools = .{ .tool = .{} } }",
        ".{ .schema = \"tiny.build.tool-catalog/v1\", .tools = .{ .tool = .{ .source_root = \"../outside\" } } }",
    }) |bytes| {
        try std.testing.expectError(error.InvalidValidationToolCatalog, toolRoots(allocator, bytes));
    }
}
