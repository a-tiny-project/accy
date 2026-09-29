const std = @import("std");
const catalog = @import("root.zig");

pub fn configure(b: *std.Build) ?*std.Build.Step {
    if (!b.isRoot()) return null;
    const enabled = b.option(bool, "build-facts", "Expose build-facts source graph export") orelse
        false;
    if (!enabled) return null;
    return b.step("build-facts", "Write build-facts.json without building or running products");
}

pub fn finalize(b: *std.Build, selected: ?*std.Build.Step) void {
    const step = selected orelse return;
    const bytes = catalog.graph.encode(b, step) catch |err| std.debug.panic(
        "cannot capture build facts: {s}",
        .{@errorName(err)},
    );
    const source = b.addWriteFiles().add("build-facts.json", bytes);
    step.dependOn(&b.addInstallFile(source, "build-facts.json").step);
}
