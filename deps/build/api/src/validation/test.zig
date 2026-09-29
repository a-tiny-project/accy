const std = @import("std");
const validation = @import("build_definition").validationBuild;

test "validation inventory discovers root tools and their consumers without fixture owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const files = .{
        .{
            "build.zig.zon",
            ".{ .dependencies = .{ .core = .{ .path = \"lib/core\" }, " ++
                ".fake = .{ .path = \"tools/style/fixture/fake\" } } }",
        },
        .{ "lib/core/build.zig.zon", ".{}" },
        .{ "tools/style/build.zig.zon", ".{ .dependencies = .{ .core = .{ .path = \"../../lib/core\" } } }" },
        .{ "tools/style/fixture/fake/build.zig.zon", ".{}" },
        .{
            "tools.zon",
            \\.{ .schema = "tiny.build.tool-catalog/v1", .tools = .{
            \\    .style = .{ .source_root = "tools/style", .available = .style },
            \\    .core = .{ .source_root = "lib/core" },
            \\} }
        },
    };
    inline for (files) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try temporary.dir.createDirPath(io, parent);
        try temporary.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    const path = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = io,
        .arena = allocator,
        .zig_exe = "zig",
        .environ_map = .init(allocator),
        .host = .{ .query = .{}, .result = @import("builtin").target },
        .generated_files = .empty,
        .wip_configuration = .init(allocator),
    };
    const b = try std.Build.create(graph, .{
        .root_dir = .{ .path = path, .handle = temporary.dir },
    }, &.{});
    const inventory = try validation.inventory.load(b, ".", "tools.zon");
    try std.testing.expectEqual(2, inventory.owners.len);
    const plan = try @import("build_definition").validation.plan.select(inventory.owners, inventory.recipes, &.{
        "lib/core/src/root.zig",
    });
    try std.testing.expectEqual(2, plan.owners.count());
    try std.testing.expectEqualStrings("tools/style", plan.uncovered_owner.?);
    const direct = try @import("build_definition").validation.plan.select(inventory.owners, inventory.recipes, &.{
        "tools/style/src/root.zig",
    });
    try std.testing.expectEqual(1, direct.owners.count());
    try std.testing.expectEqualStrings("tools/style", direct.uncovered_owner.?);
    const fixture = try @import("build_definition").validation.plan.select(
        inventory.owners,
        inventory.recipes,
        &.{"tools/style/fixture/fake/build.zig.zon"},
    );
    try std.testing.expectEqual(1, fixture.owners.count());
    try std.testing.expectEqualStrings("tools/style", fixture.uncovered_owner.?);
    try temporary.dir.deleteFile(io, "tools.zon");
    try std.testing.expectError(error.FileNotFound, validation.inventory.load(b, ".", "tools.zon"));
}
