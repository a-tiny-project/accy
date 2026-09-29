const std = @import("std");
const invocation = @import("invocation");

/// Builds the binding fixture package under its own exact invocation record,
/// so qualification never depends on how the enclosing build was launched.
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var arguments = try init.minimal.args.iterateAllocator(allocator);
    defer arguments.deinit();
    std.debug.assert(arguments.skip());
    const compiler = arguments.next() orelse return error.MissingBindingFixtureCompiler;
    const fixture = arguments.next() orelse return error.MissingBindingFixtureDirectory;
    const output = arguments.next() orelse return error.MissingBindingFixtureOutput;
    if (arguments.next() != null) return error.UnexpectedBindingFixtureArgument;
    const directory = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, fixture, allocator);
    const root = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, output, allocator);
    const args = [_][]const u8{
        "build",
        "--build-file",
        try std.fs.path.join(allocator, &.{ directory, "build.zig" }),
        "--cache-dir",
        try std.fs.path.join(allocator, &.{ root, "cache" }),
        "--prefix",
        try std.fs.path.join(allocator, &.{ root, "prefix" }),
        "--summary",
        "none",
        "-j1",
    };
    try invocation.refresh(allocator, init.environ_map, compiler, directory, &args);
    if (init.environ_map.get(invocation.record.variable) == null) return error.UnrecordedBindingFixture;
    var argv: [args.len + 1][]const u8 = undefined;
    argv[0] = compiler;
    @memcpy(argv[1..], &args);
    var child = try std.process.spawn(init.io, .{
        .argv = &argv,
        .cwd = .{ .path = directory },
        .environ_map = init.environ_map,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);
    const term = try child.wait(init.io);
    if (!term.success()) return error.BindingFixtureBuildFailed;
}
