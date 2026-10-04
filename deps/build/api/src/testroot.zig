const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) u8 {
    const allocator = init.arena.allocator();
    const args = init.minimal.args.toSlice(allocator) catch |err| {
        return writeFailure(init.io, "<arguments>", err);
    };
    if (args.len != 3) return writeFailure(
        init.io,
        "<arguments>",
        error.InvalidArgumentCount,
    );
    const source_path = args[1][0..args[1].len];
    validate(allocator, init.io, source_path) catch |err| {
        return writeFailure(init.io, source_path, err);
    };
    const stamp_path = args[2][0..args[2].len];
    std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = stamp_path,
        .data = "",
    }) catch |err| {
        return writeFailure(init.io, stamp_path, err);
    };
    return 0;
}

fn validate(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
) !void {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        source_path,
        allocator,
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
    var tree = try std.zig.Ast.parse(allocator, source, .{});
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZigSource;
    if (!hasTestDeclaration(&tree)) return error.EmptyTestRoot;
}

fn hasTestDeclaration(tree: *const std.zig.Ast) bool {
    for (tree.rootDecls()) |declaration| {
        if (tree.nodeTag(declaration) == .test_decl) return true;
    }
    return false;
}

fn writeFailure(io: std.Io, path: []const u8, err: anyerror) u8 {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    writer.interface.print(
        "test root guard: {s}: {s}\n",
        .{ path, @errorName(err) },
    ) catch {};
    writer.interface.flush() catch {};
    return 1;
}

fn parseTestDeclaration(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !bool {
    var tree = try std.zig.Ast.parse(allocator, source, .{});
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZigSource;
    return hasTestDeclaration(&tree);
}

test "top-level tests make a root nonempty" {
    try std.testing.expect(try parseTestDeclaration(
        std.testing.allocator,
        "test \"witness\" {}\n",
    ));
    try std.testing.expect(try parseTestDeclaration(
        std.testing.allocator,
        "test { _ = @import(\"suite.zig\"); }\n",
    ));
}

test "exports and nested tests do not make a test root" {
    try std.testing.expect(!try parseTestDeclaration(
        std.testing.allocator,
        "pub const owner = @import(\"owner.zig\");\n",
    ));
    try std.testing.expect(!try parseTestDeclaration(
        std.testing.allocator,
        "const Fixture = struct { test \"nested\" {} };\n",
    ));
}

test "invalid Zig source cannot be classified" {
    try std.testing.expectError(
        error.InvalidZigSource,
        parseTestDeclaration(std.testing.allocator, "test {"),
    );
}
